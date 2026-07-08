import Foundation

public struct SimLeasePaths {
    public let registry: URL
    public let lock: URL

    public init(registry: URL, lock: URL) {
        self.registry = registry
        self.lock = lock
    }

    public static func `default`() -> SimLeasePaths {
        let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".simlease")
        return SimLeasePaths(registry: base.appendingPathComponent("registry.json"),
                             lock: base.appendingPathComponent("lock"))
    }
}

public struct ClaimRequest {
    public var label: String
    public var agent: String
    public var workdir: String
    public var deviceName: String?
    public var ttl: TimeInterval
    public var rename: Bool

    public init(label: String, agent: String, workdir: String,
                deviceName: String? = nil, ttl: TimeInterval = 7200, rename: Bool = true) {
        self.label = label
        self.agent = agent
        self.workdir = workdir
        self.deviceName = deviceName
        self.ttl = ttl
        self.rename = rename
    }
}

public struct ClaimResult {
    public let udid: String
    public let deviceName: String
    public let reused: Bool
    public let created: Bool
}

public enum AllocatorError: Error, CustomStringConvertible {
    case noDeviceAvailable(String)

    public var description: String {
        switch self {
        case .noDeviceAvailable(let detail):
            return "simlease: no simulator available — \(detail)"
        }
    }
}

public struct Allocator {
    public static let defaultPreferred = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 15 Pro"]
    static let gcGrace: TimeInterval = 60

    let simctl: Simctl
    let paths: SimLeasePaths
    let preferred: [String]
    let now: () -> Date

    public init(simctl: Simctl = Simctl(), paths: SimLeasePaths = .default(),
                preferred: [String] = Allocator.defaultPreferred,
                now: @escaping () -> Date = { Date() }) {
        self.simctl = simctl
        self.paths = paths
        self.preferred = preferred
        self.now = now
    }

    public static func lockedName(label: String, original: String) -> String {
        "🔒 \(label) · \(original)"
    }

    func withLock<T>(_ body: () throws -> T) throws -> T {
        let lock = FileLock(path: paths.lock)
        try lock.acquire()
        defer { lock.release() }
        return try body()
    }

    func freeLease(_ udid: String, _ lease: Lease, presentUDIDs: Set<String>) {
        guard presentUDIDs.contains(udid) else { return }
        if lease.created {
            simctl.shutdown(udid)
            simctl.delete(udid)
        } else if lease.renamed {
            simctl.rename(udid, to: lease.originalName)
        }
    }

    func reap(_ registry: inout Registry, present: [Device]) -> [String] {
        let presentUDIDs = Set(present.map(\.udid))
        var freed: [String] = []
        for (udid, lease) in registry.leases {
            let expired = lease.expiresAt < now()
            let pastGrace = now().timeIntervalSince(lease.claimedAt) > Allocator.gcGrace
            let workdirGone = pastGrace && !FileManager.default.fileExists(atPath: lease.workdir)
            let vanished = !presentUDIDs.contains(udid)
            guard expired || workdirGone || vanished else { continue }
            freeLease(udid, lease, presentUDIDs: presentUDIDs)
            registry.leases.removeValue(forKey: udid)
            freed.append(udid)
        }
        return freed.sorted()
    }

    public func claim(_ request: ClaimRequest) throws -> ClaimResult {
        try withLock {
            var registry = try RegistryStore.load(at: paths.registry)
            let present = try simctl.devices(availableOnly: false)
            _ = reap(&registry, present: present)

            if let (udid, lease) = registry.leases.first(where: { $0.value.workdir == request.workdir }) {
                var renewed = lease
                renewed.label = request.label
                renewed.agent = request.agent
                renewed.expiresAt = now().addingTimeInterval(request.ttl)
                registry.leases[udid] = renewed
                try RegistryStore.save(registry, to: paths.registry)
                if renewed.renamed {
                    simctl.rename(udid, to: Allocator.lockedName(label: request.label,
                                                                 original: renewed.originalName))
                }
                return ClaimResult(udid: udid, deviceName: renewed.originalName,
                                   reused: true, created: false)
            }

            let available = try simctl.devices(availableOnly: true)
                .filter { $0.isAvailable && registry.leases[$0.udid] == nil }
            let order = request.deviceName.map { [$0] } ?? preferred
            var chosen: Device?
            for name in order {
                if let device = available.first(where: { $0.name == name }) {
                    chosen = device
                    break
                }
            }
            if chosen == nil, request.deviceName == nil {
                chosen = available.first(where: { $0.name.contains("iPhone") }) ?? available.first
            }

            if let device = chosen {
                let lease = Lease(label: request.label, agent: request.agent,
                                  workdir: request.workdir, originalName: device.name,
                                  renamed: request.rename, created: false,
                                  claimedAt: now(), expiresAt: now().addingTimeInterval(request.ttl))
                registry.leases[device.udid] = lease
                try RegistryStore.save(registry, to: paths.registry)
                if request.rename {
                    simctl.rename(device.udid, to: Allocator.lockedName(label: request.label,
                                                                        original: device.name))
                }
                return ClaimResult(udid: device.udid, deviceName: device.name,
                                   reused: false, created: false)
            }

            guard let deviceType = try simctl.preferredDeviceType(from: order),
                  let runtime = try simctl.latestIOSRuntime() else {
                throw AllocatorError.noDeviceAvailable(
                    "no device type or iOS runtime found; active leases: \(registry.leases.count)")
            }
            let name = Allocator.lockedName(label: request.label, original: deviceType.name)
            let udid = try simctl.create(name: name, deviceTypeID: deviceType.id, runtimeID: runtime)
            registry.leases[udid] = Lease(
                label: request.label, agent: request.agent, workdir: request.workdir,
                originalName: deviceType.name, renamed: true, created: true,
                claimedAt: now(), expiresAt: now().addingTimeInterval(request.ttl))
            try RegistryStore.save(registry, to: paths.registry)
            return ClaimResult(udid: udid, deviceName: deviceType.name, reused: false, created: true)
        }
    }

    public func release(workdir: String?, udid: String?, label: String?) throws -> Lease? {
        try withLock {
            var registry = try RegistryStore.load(at: paths.registry)
            let entry = registry.leases.first { entryUDID, lease in
                if let udid { return entryUDID == udid }
                if let label { return lease.label == label }
                return lease.workdir == workdir
            }
            guard let (foundUDID, lease) = entry else { return nil }
            let present = Set(((try? simctl.devices(availableOnly: false)) ?? []).map(\.udid))
            freeLease(foundUDID, lease, presentUDIDs: present)
            registry.leases.removeValue(forKey: foundUDID)
            try RegistryStore.save(registry, to: paths.registry)
            return lease
        }
    }

    public func renew(workdir: String, ttl: TimeInterval) throws -> Lease? {
        try withLock {
            var registry = try RegistryStore.load(at: paths.registry)
            guard let (udid, lease) = registry.leases.first(where: { $0.value.workdir == workdir }) else {
                return nil
            }
            var renewed = lease
            renewed.expiresAt = now().addingTimeInterval(ttl)
            registry.leases[udid] = renewed
            try RegistryStore.save(registry, to: paths.registry)
            return renewed
        }
    }

    public func gc() throws -> [String] {
        try withLock {
            var registry = try RegistryStore.load(at: paths.registry)
            let freed = reap(&registry, present: try simctl.devices(availableOnly: false))
            if !freed.isEmpty { try RegistryStore.save(registry, to: paths.registry) }
            return freed
        }
    }

    public func status() throws -> [(udid: String, lease: Lease, state: String?)] {
        let registry = try RegistryStore.load(at: paths.registry)
        var states: [String: String] = [:]
        for device in (try? simctl.devices(availableOnly: false)) ?? [] {
            states[device.udid] = device.state
        }
        return registry.leases
            .sorted { $0.value.claimedAt < $1.value.claimedAt }
            .map { ($0.key, $0.value, states[$0.key]) }
    }
}
