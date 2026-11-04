import Foundation
import Darwin

public enum WireError: Error { case socket(String) }

/// Newline-delimited JSON over a connected socket. One reader thread, writes under a lock.
public final class LineChannel: @unchecked Sendable {
    private let fd: Int32
    /// Guards `closed` and every write, so nothing can write once the channel is closed. That matters:
    /// after close the kernel reuses the fd number for the next connection, and a late write would hand
    /// a password to whoever that is.
    private let ioLock = NSLock()
    private var closed = false
    private var started = false
    private var released = false
    public var onLine: (@Sendable (Data) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    var rawFD: Int32 { fd }

    public var peerPID: pid_t {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0 ? pid : -1
    }

    public func start() {
        ioLock.withLock { started = true }
        let thread = Thread { [self] in readLoop() }
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func readLoop() {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(chunk, count: n)
            while let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<i)
                buffer.removeSubrange(buffer.startIndex...i)
                if !line.isEmpty { onLine?(line) }
            }
            if buffer.count > 16 * 1024 * 1024 { break }
        }
        close()
        release()
    }

    /// Gives the fd back to the system. Only once it's closed and the reader has finished.
    private func release() {
        let release = ioLock.withLock { () -> Bool in
            guard closed, !released else { return false }
            released = true
            return true
        }
        if release { Darwin.close(fd) }
    }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !closed else { return false }
        var out = data
        out.append(0x0A)
        return out.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    @discardableResult
    public func send(json object: Any) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        return send(data)
    }

    public func close() {
        // Wakes the reader and any blocked write first, so taking the lock below can't wait forever.
        shutdown(fd, SHUT_RDWR)
        let (already, reader) = ioLock.withLock { () -> (Bool, Bool) in
            let already = closed
            closed = true
            return (already, started)
        }
        guard !already else { return }
        if !reader { release() }
        onClose?()
    }
}

private func withSocketAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw WireError.socket("socket path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        dst.copyBytes(from: bytes)
        dst[bytes.count] = 0
    }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}

/// Who connected, as the kernel recorded it at connect time. Unlike a pid, this can't be passed along by
/// connecting first and then starting a different program.
extension LineChannel {
    public var peerAuditToken: audit_token_t? {
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(rawFD, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 ? token : nil
    }
}

public func connectUnixSocket(path: String) throws -> LineChannel {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw WireError.socket("socket failed") }
    let result = try withSocketAddress(path) { connect(fd, $0, $1) }
    guard result == 0 else {
        Darwin.close(fd)
        throw WireError.socket("connect failed: \(String(cString: strerror(errno)))")
    }
    return LineChannel(fd: fd)
}

/// A listening socket only your user can reach (0600, in a 0700 directory).
public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private var fd: Int32 = -1

    public init(path: String) { self.path = path }

    public func start(onAccept: @escaping @Sendable (LineChannel) -> Void) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw WireError.socket("socket failed") }
        let previous = umask(0o177)
        defer { umask(previous) }
        let bound = try withSocketAddress(path) { Darwin.bind(fd, $0, $1) }
        guard bound == 0, listen(fd, 16) == 0 else { throw WireError.socket("bind failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        let listener = fd
        let thread = Thread {
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { break }
                onAccept(LineChannel(fd: client))
            }
        }
        thread.start()
    }

    public func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        unlink(path)
    }
}
