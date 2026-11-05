import Foundation
import Darwin

public enum HiddenChromeError: Error, Equatable {
    case noBrowser
    case failed(String)
}

/// A headless Chrome with its own throwaway profile, started over a debugging pipe so no port is open
/// for anything else to attach to. Used for Apple's helper, which only answers a browser, and for
/// session files.
public final class HiddenChrome: @unchecked Sendable {
    public struct NativeHost {
        public var name: String
        public var manifest: [String: Any]
        public init(name: String, manifest: [String: Any]) {
            self.name = name
            self.manifest = manifest
        }
    }

    private let binary: String
    private let profile: URL
    private let extensions: [String]
    private let nativeHosts: [NativeHost]
    private let environment: [String: String]
    private var pid: pid_t = 0
    private var toChrome: Int32 = -1
    private var fromChrome: Int32 = -1
    private let lock = NSLock()
    private var nextID = 1
    private var waiting: [Int: (Result<[String: Any], Error>) -> Void] = [:]

    public static func findBrowser() -> String? {
        let candidates = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What macOS calls the hidden browser, for instance on Apple's Touch ID sheet.
    public static var browserName: String? {
        findBrowser().map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public init(binary: String, profile: URL, extensions: [String], nativeHosts: [NativeHost], environment: [String: String] = [:]) {
        self.binary = binary
        self.profile = profile
        self.extensions = extensions
        self.nativeHosts = nativeHosts
        self.environment = environment
    }

    public var processID: pid_t { pid }

    public var isRunning: Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    public func start() async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: profile)
        let hostsDir = profile.appendingPathComponent("NativeMessagingHosts")
        try fm.createDirectory(at: hostsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for host in nativeHosts {
            let data = try JSONSerialization.data(withJSONObject: host.manifest, options: [.prettyPrinted])
            try data.write(to: hostsDir.appendingPathComponent("\(host.name).json"))
        }

        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0, pipe(&outPipe) == 0 else { throw HiddenChromeError.failed("pipe") }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Chrome's debugging pipe is always fd 3 (it reads) and fd 4 (it writes).
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 3)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 4)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawn_file_actions_addinherit_np(&actions, 3)
        posix_spawn_file_actions_addinherit_np(&actions, 4)

        let args = [binary,
                    "--user-data-dir=\(profile.path)",
                    "--remote-debugging-pipe",
                    "--enable-unsafe-extension-debugging",
                    "--headless=new",
                    "--no-first-run",
                    "--no-default-browser-check",
                    "--disable-background-timer-throttling",
                    "--disable-backgrounding-occluded-windows",
                    "--disable-features=Translate,OptimizationHints,MediaRouter",
                    "--password-store=basic",
                    "--use-mock-keychain",
                    "about:blank"]
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in environment { merged[k] = v }
        var envp: [UnsafeMutablePointer<CChar>?] = merged.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        var child: pid_t = 0
        let status = posix_spawn(&child, binary, &actions, &attr, &argv, &envp)
        guard status == 0 else { throw HiddenChromeError.failed("spawn \(status)") }
        pid = child
        close(inPipe[0])
        close(outPipe[1])
        toChrome = inPipe[1]
        fromChrome = outPipe[0]
        signal(SIGPIPE, SIG_IGN)
        startReader()

        for path in extensions {
            _ = try await send("Extensions.loadUnpacked", ["path": path])
        }
    }

    private func startReader() {
        let fd = fromChrome
        let thread = Thread { [weak self] in
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
                while let i = buffer.firstIndex(of: 0) {
                    let line = buffer.subdata(in: buffer.startIndex..<i)
                    buffer.removeSubrange(buffer.startIndex...i)
                    self?.deliver(line)
                }
            }
            self?.failAll()
        }
        thread.start()
    }

    private func deliver(_ line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = object["id"] as? Int else { return }
        lock.lock()
        let callback = waiting.removeValue(forKey: id)
        lock.unlock()
        if let error = object["error"] as? [String: Any] {
            callback?(.failure(HiddenChromeError.failed(error["message"] as? String ?? "devtools error")))
        } else {
            callback?(.success(object["result"] as? [String: Any] ?? [:]))
        }
    }

    private func failAll() {
        lock.lock()
        let all = waiting
        waiting = [:]
        lock.unlock()
        for (_, c) in all { c(.failure(HiddenChromeError.failed("browser closed"))) }
    }

    @discardableResult
    public func send(_ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextID
            nextID += 1
            waiting[id] = { continuation.resume(with: $0) }
            lock.unlock()
            guard var data = try? JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params] as [String: Any]) else {
                lock.lock()
                let c = waiting.removeValue(forKey: id)
                lock.unlock()
                c?(.failure(HiddenChromeError.failed("encode")))
                return
            }
            data.append(0)
            let ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(toChrome, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
            if !ok {
                lock.lock()
                let c = waiting.removeValue(forKey: id)
                lock.unlock()
                c?(.failure(HiddenChromeError.failed("write")))
            }
        }
    }

    /// Opens a tab through the debugging pipe.
    public func openTab(_ url: String) async throws {
        _ = try await send("Target.createTarget", ["url": url])
    }

    public func stop(removeProfile: Bool = true) {
        if pid > 0 {
            kill(pid, SIGTERM)
            let child = pid
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { kill(child, SIGKILL) }
            var status: Int32 = 0
            for _ in 0..<40 {
                if waitpid(child, &status, WNOHANG) == child { break }
                usleep(50_000)
            }
            pid = 0
        }
        if toChrome >= 0 { close(toChrome); toChrome = -1 }
        if fromChrome >= 0 { close(fromChrome); fromChrome = -1 }
        if removeProfile { try? FileManager.default.removeItem(at: profile) }
    }

    deinit { stop(removeProfile: false) }
}

public func nativeHostManifest(path: String, allowedExtensionIDs: [String]) -> [String: Any] {
    ["name": DoormanConstants.nativeHostName,
     "description": "Doorman native host",
     "path": path,
     "type": "stdio",
     "allowed_origins": allowedExtensionIDs.map { "chrome-extension://\($0)/" }]
}
