import Foundation

public enum Focus {
    public static func bringToFront(udid: String, deviceDisplayName: String,
                                    runner: ProcessRunner = ShellRunner()) {
        _ = try? runner.run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid])
        let escaped = deviceDisplayName.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Simulator" to activate
        tell application "System Events" to tell process "Simulator"
            repeat with w in windows
                if name of w contains "\(escaped)" then
                    perform action "AXRaise" of w
                end if
            end repeat
        end tell
        """
        _ = try? runner.run(["osascript", "-e", script])
    }
}
