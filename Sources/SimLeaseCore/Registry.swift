import Foundation

public struct Lease: Codable, Equatable {
    public var label: String
    public var agent: String
    public var workdir: String
    public var originalName: String
    public var renamed: Bool
    public var created: Bool
    public var claimedAt: Date
    public var expiresAt: Date

    public init(label: String, agent: String, workdir: String, originalName: String,
                renamed: Bool, created: Bool, claimedAt: Date, expiresAt: Date) {
        self.label = label
        self.agent = agent
        self.workdir = workdir
        self.originalName = originalName
        self.renamed = renamed
        self.created = created
        self.claimedAt = claimedAt
        self.expiresAt = expiresAt
    }
}

public struct Registry: Codable, Equatable {
    public var schema: Int
    public var leases: [String: Lease]

    public static let empty = Registry(schema: 1, leases: [:])
}

public enum RegistryError: Error, CustomStringConvertible {
    case unsupportedSchema(Int)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version):
            return "registry schema \(version) is newer than this simlease understands — upgrade simlease"
        }
    }
}

public enum RegistryStore {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func load(at url: URL) throws -> Registry {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        do {
            let registry = try decoder.decode(Registry.self, from: data)
            guard registry.schema <= 1 else { throw RegistryError.unsupportedSchema(registry.schema) }
            return registry
        } catch let error as RegistryError {
            throw error
        } catch {
            try? FileManager.default.removeItem(atPath: url.path + ".corrupt")
            try? FileManager.default.moveItem(atPath: url.path, toPath: url.path + ".corrupt")
            FileHandle.standardError.write(Data("simlease: registry was corrupt, backed up to .corrupt\n".utf8))
            return .empty
        }
    }

    public static func save(_ registry: Registry, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(registry)
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
    }
}
