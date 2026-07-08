import AppKit
import SwiftUI
import SimLeaseCore

@main
struct SimLeaseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var board = LeaseBoard()

    var body: some Scene {
        MenuBarExtra {
            if board.rows.isEmpty {
                Text("No simulators leased")
            }
            ForEach(board.rows) { row in
                Menu {
                    Button("Focus window") { board.focus(row) }
                    Button("Release lease") { board.release(row) }
                    Button("Copy UDID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(row.id, forType: .string)
                    }
                } label: {
                    Text(rowTitle(row))
                }
            }
            Divider()
            Button("Run GC") { board.runGC() }
            Button("Refresh") { board.refresh() }
            Divider()
            Button("Quit SimLease") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "iphone.gen3")
        }
    }

    func rowTitle(_ row: BoardRow) -> String {
        let dot = row.booted ? "🟢" : "⚪️"
        let expired = row.expired ? " (expired)" : ""
        return "\(dot) \(row.lease.label) — \(row.lease.originalName)\(expired) · \(row.lease.agent)"
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
