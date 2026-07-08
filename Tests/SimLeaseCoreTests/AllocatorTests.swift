import XCTest
@testable import SimLeaseCore

final class AllocatorTests: XCTestCase {
    var dir: URL!
    var runner: FakeRunner!
    var now: Date!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        runner = FakeRunner()
        now = Date(timeIntervalSince1970: 2_000_000)
        stubDevices([("AAA", "iPhone 17 Pro", "Shutdown"), ("BBB", "iPhone 16 Pro", "Shutdown")])
    }

    func stubDevices(_ devs: [(String, String, String)]) {
        let items = devs.map {
            #"{"udid": "\#($0.0)", "name": "\#($0.1)", "state": "\#($0.2)", "isAvailable": true}"#
        }.joined(separator: ",")
        let json = #"{"devices": {"iOS-26-0": [\#(items)]}}"#
        runner.setResponse("xcrun simctl list -j devices available",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        runner.setResponse("xcrun simctl list -j devices",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
    }

    func makeAllocator() -> Allocator {
        Allocator(
            simctl: Simctl(runner: runner),
            paths: SimLeasePaths(
                registry: dir.appendingPathComponent("registry.json"),
                lock: dir.appendingPathComponent("lock")),
            now: { self.now })
    }

    func wt(_ name: String) -> String {
        let path = dir.appendingPathComponent(name).path
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func req(_ label: String, workdir: String? = nil) -> ClaimRequest {
        ClaimRequest(label: label, agent: "claude-code", workdir: workdir ?? wt("wt-a"),
                     deviceName: nil, ttl: 7200, rename: true)
    }

    func loadRegistry() throws -> Registry {
        try RegistryStore.load(at: dir.appendingPathComponent("registry.json"))
    }

    func testClaimPrefersIPhone17Pro() throws {
        let result = try makeAllocator().claim(req("APP-1"))
        XCTAssertEqual(result.udid, "AAA")
        XCTAssertFalse(result.created)
        XCTAssertTrue(runner.calls.contains(["xcrun", "simctl", "rename", "AAA", "🔒 APP-1 · iPhone 17 Pro"]))
    }

    func testStickyReclaimSameWorkdirReusesAndRenews() throws {
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1"))
        now = now.addingTimeInterval(3600)
        let second = try alloc.claim(req("APP-1"))
        XCTAssertEqual(second.udid, "AAA")
        XCTAssertTrue(second.reused)
        let lease = try loadRegistry().leases["AAA"]
        XCTAssertEqual(lease?.expiresAt, now.addingTimeInterval(7200))
    }

    func testSecondWorkdirGetsDifferentDevice() throws {
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1", workdir: wt("wt-a")))
        let second = try alloc.claim(req("APP-2", workdir: wt("wt-b")))
        XCTAssertEqual(second.udid, "BBB")
    }

    func testExpiredLeaseIsReclaimableAndNameRestored() throws {
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1", workdir: wt("wt-a")))
        now = now.addingTimeInterval(8000)
        let second = try alloc.claim(req("APP-2", workdir: wt("wt-b")))
        XCTAssertEqual(second.udid, "AAA")
        XCTAssertTrue(runner.calls.contains(["xcrun", "simctl", "rename", "AAA", "iPhone 17 Pro"]))
    }

    func testAllTakenCreatesCloneOnLatestRuntime() throws {
        runner.setResponse("xcrun simctl list -j devicetypes", ProcessResult(status: 0, stdout:
            #"{"devicetypes": [{"name": "iPhone 17 Pro", "identifier": "dt-17"}]}"#, stderr: ""))
        runner.setResponse("xcrun simctl list -j runtimes", ProcessResult(status: 0, stdout:
            #"{"runtimes": [{"identifier": "rt-26", "name": "iOS 26.0", "version": "26.0", "isAvailable": true}]}"#, stderr: ""))
        runner.setResponse("xcrun simctl create", ProcessResult(status: 0, stdout: "NEW\n", stderr: ""))
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1", workdir: wt("wt-a")))
        _ = try alloc.claim(req("APP-2", workdir: wt("wt-b")))
        let third = try alloc.claim(req("APP-3", workdir: wt("wt-c")))
        XCTAssertEqual(third.udid, "NEW")
        XCTAssertTrue(third.created)
        XCTAssertTrue(runner.calls.contains {
            Array($0.prefix(4)) == ["xcrun", "simctl", "create", "🔒 APP-3 · iPhone 17 Pro"]
        })
    }

    func testReleaseRestoresNameAndDeletesOnlyCreatedSims() throws {
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1"))
        let released = try alloc.release(workdir: wt("wt-a"), udid: nil, label: nil)
        XCTAssertEqual(released?.originalName, "iPhone 17 Pro")
        XCTAssertTrue(runner.calls.contains(["xcrun", "simctl", "rename", "AAA", "iPhone 17 Pro"]))
        XCTAssertFalse(runner.calls.contains(["xcrun", "simctl", "delete", "AAA"]))
        XCTAssertTrue(try loadRegistry().leases.isEmpty)
    }

    func testRenewExtendsLease() throws {
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1"))
        now = now.addingTimeInterval(3600)
        let renewed = try alloc.renew(workdir: wt("wt-a"), ttl: 7200)
        XCTAssertEqual(renewed?.expiresAt, now.addingTimeInterval(7200))
        XCTAssertNil(try alloc.renew(workdir: "/tmp/none", ttl: 7200))
    }

    func testGcReapsDeadWorkdirsAfterGrace() throws {
        let workdir = dir.appendingPathComponent("gone")
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1", workdir: workdir.path))
        XCTAssertEqual(try alloc.gc(), [])
        try FileManager.default.removeItem(at: workdir)
        XCTAssertEqual(try alloc.gc(), [])
        now = now.addingTimeInterval(120)
        XCTAssertEqual(try alloc.gc(), ["AAA"])
        XCTAssertTrue(runner.calls.contains(["xcrun", "simctl", "rename", "AAA", "iPhone 17 Pro"]))
    }

    func testGcWithNothingToReapDoesNotWriteRegistry() throws {
        XCTAssertEqual(try makeAllocator().gc(), [])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("registry.json").path))
    }

    func testStatusListsLeasesWithDeviceState() throws {
        stubDevices([("AAA", "iPhone 17 Pro", "Booted"), ("BBB", "iPhone 16 Pro", "Shutdown")])
        let alloc = makeAllocator()
        _ = try alloc.claim(req("APP-1"))
        let rows = try alloc.status()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].udid, "AAA")
        XCTAssertEqual(rows[0].state, "Booted")
        XCTAssertEqual(rows[0].lease.label, "APP-1")
    }

    func testParallelClaimsGetDistinctUDIDs() throws {
        stubDevices([("AAA", "iPhone 17 Pro", "Shutdown"), ("BBB", "iPhone 16 Pro", "Shutdown"),
                     ("CCC", "iPhone 15 Pro", "Shutdown"), ("DDD", "iPhone 14", "Shutdown")])
        let results = UnsafeMutablePointer<[String]>.allocate(capacity: 1)
        results.initialize(to: [])
        let queue = DispatchQueue(label: "results")
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            if let r = try? self.makeAllocator().claim(self.req("T\(i)", workdir: self.wt("wt-\(i)"))) {
                queue.sync { results.pointee.append(r.udid) }
            }
        }
        XCTAssertEqual(Set(results.pointee).count, 4)
        results.deinitialize(count: 1)
        results.deallocate()
    }
}
