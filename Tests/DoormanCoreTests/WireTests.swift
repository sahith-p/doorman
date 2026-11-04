import XCTest
import Darwin
@testable import DoormanCore

final class WireTests: XCTestCase {
    private func pair() -> (LineChannel, LineChannel) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        return (LineChannel(fd: fds[0]), LineChannel(fd: fds[1]))
    }

    func testNothingCanBeWrittenAfterClose() {
        let (a, b) = pair()
        defer { b.close() }
        a.start()
        XCTAssertTrue(a.send(Data("hello".utf8)))
        a.close()
        // A late write mustn't land on whatever connection gets this fd number next.
        XCTAssertFalse(a.send(Data("password".utf8)))
    }

    func testClosingWithoutStartingStillReleases() {
        let (a, b) = pair()
        defer { b.close() }
        a.close()
        XCTAssertFalse(a.send(Data("x".utf8)))
    }

    func testTheOtherEndClosingStopsWrites() {
        let (a, b) = pair()
        a.start()
        let closed = expectation(description: "closed")
        a.onClose = { closed.fulfill() }
        b.close()
        wait(for: [closed], timeout: 2)
        XCTAssertFalse(a.send(Data("password".utf8)))
    }

    func testAHugeWaitFromAnAgentCantCrashTheApp() {
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": 1e300]), 300)
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": -5]), 0)
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": Double.infinity]), 50)
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": Double.nan]), 50)
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": 12]), 12)
        XCTAssertEqual(Daemon.waitSeconds(["wait_seconds": "not a number"]), 50)
        XCTAssertEqual(Daemon.waitSeconds([:]), 50)
    }
}
