import ArgumentParser
import Foundation
import SimLeaseCore

func stderrPrint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func currentWorkdir() -> String {
    let git = try? ShellRunner().run(["git", "rev-parse", "--show-toplevel"])
    if let git, git.status == 0 {
        let path = git.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty { return path }
    }
    return FileManager.default.currentDirectoryPath
}

func defaultLabel() -> String {
    let git = try? ShellRunner().run(["git", "rev-parse", "--abbrev-ref", "HEAD"])
    if let git, git.status == 0 {
        let branch = git.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !branch.isEmpty, branch != "HEAD" { return branch }
    }
    return URL(fileURLWithPath: currentWorkdir()).lastPathComponent
}

func defaultAgent() -> String {
    let env = ProcessInfo.processInfo.environment
    if let explicit = env["SIMLEASE_AGENT"] { return explicit }
    if env["CLAUDECODE"] != nil || env["CLAUDE_CODE"] != nil { return "claude-code" }
    if env.keys.contains(where: { $0.hasPrefix("CODEX") }) { return "codex" }
    return env["USER"] ?? "unknown"
}

func parseTTL(_ raw: String) throws -> TimeInterval {
    let value = raw.lowercased()
    if value.hasSuffix("h"), let hours = Double(value.dropLast()) { return hours * 3600 }
    if value.hasSuffix("m"), let minutes = Double(value.dropLast()) { return minutes * 60 }
    if let seconds = Double(value) { return seconds }
    throw ValidationError("invalid --ttl '\(raw)' (use 7200, 90m or 2h)")
}

func remaining(_ lease: Lease, now: Date = Date()) -> String {
    let seconds = Int(lease.expiresAt.timeIntervalSince(now))
    if seconds <= 0 { return "expired" }
    return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m left" : "\(seconds / 60)m left"
}

@main
struct Simlease: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simlease",
        abstract: "Lease iOS simulators to AI agents — locks, task names and TTLs.",
        subcommands: [Claim.self, Release.self, Renew.self, Status.self, GC.self, FocusCommand.self],
        defaultSubcommand: Claim.self)
}

struct Claim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claim", abstract: "Claim or reuse a simulator for this directory.")

    @Option(help: "Task label shown in the simulator window title (default: git branch).")
    var label: String?

    @Option(help: "Agent name recorded in the lease (default: detected from env).")
    var agent: String?

    @Option(help: "Exact device name to claim, e.g. 'iPhone 17 Pro'.")
    var device: String?

    @Option(help: "Lease duration: 7200, 90m or 2h (default 2h).")
    var ttl: String = "2h"

    @Flag(help: "Do not rename the simulator.")
    var noRename = false

    @Flag(help: "Print the full lease as JSON instead of just the UDID.")
    var json = false

    @Flag(help: "Do not boot the simulator after claiming.")
    var noBoot = false

    func run() throws {
        let request = ClaimRequest(
            label: label ?? defaultLabel(), agent: agent ?? defaultAgent(),
            workdir: currentWorkdir(), deviceName: device,
            ttl: try parseTTL(ttl), rename: !noRename)
        let result = try Allocator().claim(request)
        let verb = result.created ? "Created" : (result.reused ? "Reusing" : "Assigned")
        stderrPrint("🔒 \(verb) \(result.deviceName) (\(result.udid.prefix(8))) for \"\(request.label)\"")
        if !noBoot { Simctl().boot(result.udid) }
        if json {
            print(#"{"udid": "\#(result.udid)", "device": "\#(result.deviceName)", "label": "\#(request.label)", "reused": \#(result.reused), "created": \#(result.created)}"#)
        } else {
            print(result.udid)
        }
    }
}

struct Release: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release", abstract: "Release this directory's simulator.")

    @Option(help: "Release by UDID instead of the current directory.")
    var udid: String?

    @Option(help: "Release by task label instead of the current directory.")
    var label: String?

    func run() throws {
        let workdir = (udid == nil && label == nil) ? currentWorkdir() : nil
        guard let lease = try Allocator().release(workdir: workdir, udid: udid, label: label) else {
            stderrPrint("simlease: nothing to release")
            return
        }
        stderrPrint("🧹 Released \(lease.originalName) (\"\(lease.label)\")")
    }
}

struct Renew: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "renew", abstract: "Extend this directory's lease.")

    @Option(help: "New lease duration: 7200, 90m or 2h (default 2h).")
    var ttl: String = "2h"

    func run() throws {
        guard let lease = try Allocator().renew(workdir: currentWorkdir(), ttl: try parseTTL(ttl)) else {
            stderrPrint("simlease: no lease for this directory — run 'simlease claim'")
            throw ExitCode(1)
        }
        stderrPrint("🔒 Renewed \"\(lease.label)\" — \(remaining(lease))")
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show all leases.")

    @Flag(help: "Print the raw registry as JSON.")
    var json = false

    func run() throws {
        if json {
            let registry = try RegistryStore.load(at: SimLeasePaths.default().registry)
            let data = try RegistryStore.encoder.encode(registry)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        let rows = try Allocator().status()
        if rows.isEmpty {
            print("(no simulators leased)")
            return
        }
        for row in rows {
            let state = row.state ?? "missing"
            print("\(row.lease.label)  —  \(row.lease.originalName) [\(state)]  \(row.lease.agent)  \(remaining(row.lease))")
            print("    \(row.udid)  \(row.lease.workdir)")
        }
    }
}

struct GC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gc", abstract: "Reap expired leases and dead workdirs.")

    func run() throws {
        let freed = try Allocator().gc()
        stderrPrint("simlease: freed \(freed.count) lease\(freed.count == 1 ? "" : "s")")
    }
}

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus", abstract: "Bring a leased simulator's window to the front.")

    @Argument(help: "Lease label or UDID (omit for this directory's sim).")
    var target: String?

    func run() throws {
        let rows = try Allocator().status()
        let workdir = currentWorkdir()
        let match = rows.first { row in
            guard let target else { return row.lease.workdir == workdir }
            return row.udid == target || row.lease.label == target
        }
        guard let match else {
            stderrPrint("simlease: no matching lease")
            throw ExitCode(1)
        }
        let title = match.lease.renamed
            ? Allocator.lockedName(label: match.lease.label, original: match.lease.originalName)
            : match.lease.originalName
        Focus.bringToFront(udid: match.udid, deviceDisplayName: title)
    }
}
