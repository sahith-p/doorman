import Foundation
import Darwin
import DoormanCore

// Chrome starts this and talks to it over stdin/stdout, with a 4-byte length before each message. It
// passes messages between Chrome and the Doorman app and does nothing else. Chrome passes the calling
// extension's origin as the first argument, and the app decides what that extension may do.

let origin = CommandLine.arguments.dropFirst().first(where: { $0.hasPrefix("chrome-extension://") }) ?? ""

func readExactly(_ count: Int) -> Data? {
    var out = Data(capacity: count)
    var chunk = [UInt8](repeating: 0, count: min(count, 65536))
    while out.count < count {
        let n = read(STDIN_FILENO, &chunk, min(count - out.count, chunk.count))
        if n <= 0 { return nil }
        out.append(chunk, count: n)
    }
    return out
}

let stdoutLock = NSLock()
func writeFrame(_ data: Data) {
    stdoutLock.lock()
    defer { stdoutLock.unlock() }
    var length = UInt32(data.count).littleEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(data)
    frame.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let n = write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
            if n <= 0 { exit(0) }
            offset += n
        }
    }
}

var channel: LineChannel?
// Doorman may not be running. The extension tries again every minute, so don't wait around.
for _ in 0..<10 {
    if let c = try? connectUnixSocket(path: DoormanConstants.socketPath) {
        channel = c
        break
    }
    usleep(100_000)
}
guard let channel else {
    writeFrame(Data(#"{"doorman":"app_not_running"}"#.utf8))
    exit(1)
}

channel.onLine = { writeFrame($0) }
channel.onClose = { exit(0) }
channel.start()
channel.send(json: ["hostHello": ["origin": origin]])

while true {
    guard let header = readExactly(4) else { break }
    let length = header.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
    guard length <= 64 * 1024 * 1024, let body = readExactly(Int(length)) else { break }
    channel.send(body)
}
channel.close()
exit(0)
