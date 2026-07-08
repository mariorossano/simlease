import Foundation

public struct ProcessResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner {
    func run(_ arguments: [String]) throws -> ProcessResult
}

public struct ShellRunner: ProcessRunner {
    public init() {}

    public func run(_ arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

public struct Device: Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let runtime: String
    public let isAvailable: Bool
}

public enum SimctlError: Error, CustomStringConvertible {
    case commandFailed(String, String)

    public var description: String {
        switch self {
        case .commandFailed(let command, let stderr):
            return "simctl \(command) failed: \(stderr)"
        }
    }
}

public struct Simctl {
    let runner: ProcessRunner

    public init(runner: ProcessRunner = ShellRunner()) {
        self.runner = runner
    }

    func listJSON(_ what: String, extra: [String] = []) throws -> [String: Any] {
        let result = try runner.run(["xcrun", "simctl", "list", "-j", what] + extra)
        let data = Data(result.stdout.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    public func devices(availableOnly: Bool) throws -> [Device] {
        let extra = availableOnly ? ["available"] : []
        let data = try listJSON("devices", extra: extra)["devices"] as? [String: [[String: Any]]] ?? [:]
        var result: [Device] = []
        for (runtime, list) in data {
            for entry in list {
                result.append(Device(
                    udid: entry["udid"] as? String ?? "",
                    name: entry["name"] as? String ?? "?",
                    state: entry["state"] as? String ?? "?",
                    runtime: runtime,
                    isAvailable: entry["isAvailable"] as? Bool ?? true))
            }
        }
        return result.sorted { $0.udid < $1.udid }
    }

    public func create(name: String, deviceTypeID: String, runtimeID: String) throws -> String {
        let result = try runner.run(["xcrun", "simctl", "create", name, deviceTypeID, runtimeID])
        guard result.status == 0 else { throw SimctlError.commandFailed("create", result.stderr) }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func delete(_ udid: String) {
        _ = try? runner.run(["xcrun", "simctl", "delete", udid])
    }

    public func shutdown(_ udid: String) {
        _ = try? runner.run(["xcrun", "simctl", "shutdown", udid])
    }

    public func boot(_ udid: String) {
        _ = try? runner.run(["xcrun", "simctl", "boot", udid])
    }

    @discardableResult
    public func rename(_ udid: String, to name: String) -> Bool {
        guard let result = try? runner.run(["xcrun", "simctl", "rename", udid, name]) else { return false }
        if result.status != 0 {
            FileHandle.standardError.write(Data("simlease: rename of \(udid.prefix(8)) failed (non-fatal)\n".utf8))
        }
        return result.status == 0
    }

    public func preferredDeviceType(from preferred: [String]) throws -> (name: String, id: String)? {
        let list = try listJSON("devicetypes")["devicetypes"] as? [[String: Any]] ?? []
        var byName: [String: String] = [:]
        for deviceType in list {
            if let name = deviceType["name"] as? String, let id = deviceType["identifier"] as? String {
                byName[name] = id
            }
        }
        for name in preferred {
            if let id = byName[name] { return (name, id) }
        }
        for deviceType in list {
            if let name = deviceType["name"] as? String, name.contains("iPhone"),
               let id = deviceType["identifier"] as? String {
                return (name, id)
            }
        }
        return nil
    }

    public func latestIOSRuntime() throws -> String? {
        let list = try listJSON("runtimes")["runtimes"] as? [[String: Any]] ?? []
        return list
            .filter {
                ($0["isAvailable"] as? Bool ?? false) && ($0["name"] as? String ?? "").hasPrefix("iOS")
            }
            .sorted {
                ($0["version"] as? String ?? "").compare(
                    $1["version"] as? String ?? "", options: .numeric) == .orderedDescending
            }
            .first?["identifier"] as? String
    }
}
