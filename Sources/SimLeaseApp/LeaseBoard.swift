import Foundation
import SimLeaseCore

struct BoardRow: Identifiable {
    let id: String
    let lease: Lease
    let booted: Bool
    let expired: Bool
}

@MainActor
final class LeaseBoard: ObservableObject {
    @Published var rows: [BoardRow] = []
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        refresh()
        watchRegistry()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let result = (try? Allocator().status()) ?? []
        let now = Date()
        rows = result.map { row in
            BoardRow(id: row.udid, lease: row.lease,
                     booted: row.state == "Booted", expired: row.lease.expiresAt < now)
        }
    }

    private func watchRegistry() {
        let url = SimLeasePaths.default().registry.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func focus(_ row: BoardRow) {
        let title = row.lease.renamed
            ? Allocator.lockedName(label: row.lease.label, original: row.lease.originalName)
            : row.lease.originalName
        Focus.bringToFront(udid: row.id, deviceDisplayName: title)
    }

    func release(_ row: BoardRow) {
        _ = try? Allocator().release(workdir: nil, udid: row.id, label: nil)
        refresh()
    }

    func runGC() {
        _ = try? Allocator().gc()
        refresh()
    }
}
