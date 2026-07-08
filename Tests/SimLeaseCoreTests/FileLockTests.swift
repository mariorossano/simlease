import XCTest
@testable import SimLeaseCore

final class FileLockTests: XCTestCase {
    var path: URL!

    override func setUp() {
        path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("lock")
    }

    func testAcquireCreatesLockDirAndReleaseRemovesIt() throws {
        let lock = FileLock(path: path)
        try lock.acquire()
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        lock.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testSecondAcquireTimesOutWhileHeld() throws {
        let first = FileLock(path: path)
        try first.acquire()
        let second = FileLock(path: path, staleAfter: 60)
        XCTAssertThrowsError(try second.acquire(timeout: 1))
        first.release()
    }

    func testStaleLockIsStolen() throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -120)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        let lock = FileLock(path: path, staleAfter: 10)
        try lock.acquire(timeout: 2)
        lock.release()
    }

    func testParallelAcquireIsExclusive() throws {
        let counter = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        counter.pointee = 0
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let lock = FileLock(path: path)
            guard (try? lock.acquire(timeout: 30)) != nil else { return }
            let value = counter.pointee
            usleep(20_000)
            counter.pointee = value + 1
            lock.release()
        }
        XCTAssertEqual(counter.pointee, 8)
        counter.deallocate()
    }
}
