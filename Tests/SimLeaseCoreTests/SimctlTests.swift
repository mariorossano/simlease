import XCTest
@testable import SimLeaseCore

final class SimctlTests: XCTestCase {
    func testDevicesParsesFlattenedList() throws {
        let json = """
        {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"udid": "AAA", "name": "iPhone 17 Pro", "state": "Booted", "isAvailable": true},
            {"udid": "BBB", "name": "iPhone 16 Pro", "state": "Shutdown", "isAvailable": true}
        ]}}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j devices",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        let devices = try Simctl(runner: runner).devices(availableOnly: false)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices.first(where: { $0.udid == "AAA" })?.state, "Booted")
    }

    func testCreateReturnsTrimmedUDID() throws {
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl create",
                           ProcessResult(status: 0, stdout: "NEW-UDID\n", stderr: ""))
        let udid = try Simctl(runner: runner)
            .create(name: "X", deviceTypeID: "dt", runtimeID: "rt")
        XCTAssertEqual(udid, "NEW-UDID")
    }

    func testLatestIOSRuntimePicksHighestVersion() throws {
        let json = """
        {"runtimes": [
            {"identifier": "old", "name": "iOS 17.5", "version": "17.5", "isAvailable": true},
            {"identifier": "new", "name": "iOS 26.0", "version": "26.0", "isAvailable": true},
            {"identifier": "tv", "name": "tvOS 26.0", "version": "26.0", "isAvailable": true}
        ]}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j runtimes",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        XCTAssertEqual(try Simctl(runner: runner).latestIOSRuntime(), "new")
    }

    func testPreferredDeviceTypePicksFirstMatch() throws {
        let json = """
        {"devicetypes": [
            {"name": "iPhone 15 Pro", "identifier": "dt-15"},
            {"name": "iPhone 17 Pro", "identifier": "dt-17"}
        ]}
        """
        let runner = FakeRunner()
        runner.setResponse("xcrun simctl list -j devicetypes",
                           ProcessResult(status: 0, stdout: json, stderr: ""))
        let result = try Simctl(runner: runner)
            .preferredDeviceType(from: ["iPhone 17 Pro", "iPhone 16 Pro"])
        XCTAssertEqual(result?.id, "dt-17")
    }
}
