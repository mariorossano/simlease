import Foundation

public enum LockError: Error, CustomStringConvertible {
    case timedOut(String)

    public var description: String {
        switch self {
        case .timedOut(let path):
            return "simlease: could not acquire lock at \(path)"
        }
    }
}

public final class FileLock {
    let path: URL
    let staleAfter: TimeInterval
    var held = false

    public init(path: URL, staleAfter: TimeInterval = 10) {
        self.path = path
        self.staleAfter = staleAfter
    }

    public func acquire(timeout: TimeInterval = 20) throws {
        let fm = FileManager.default
        try? fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            do {
                try fm.createDirectory(at: path, withIntermediateDirectories: false)
                held = true
                return
            } catch {
                if let mtime = (try? fm.attributesOfItem(atPath: path.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(mtime) > staleAfter {
                    FileHandle.standardError.write(Data("simlease: stealing stale lock\n".utf8))
                    try? fm.removeItem(at: path)
                    continue
                }
                if Date() > deadline { throw LockError.timedOut(path.path) }
                usleep(200_000)
            }
        }
    }

    public func release() {
        guard held else { return }
        held = false
        try? FileManager.default.removeItem(at: path)
    }

    deinit { release() }
}
