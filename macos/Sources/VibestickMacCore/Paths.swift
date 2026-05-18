import Foundation

public enum VibestickPaths {
    public static let bundleIdentifier = "com.pzy.vibestick"
    public static let helperIdentifier = "com.pzy.vibestick.helper"
    public static let installedHelperPath = "/Library/PrivilegedHelperTools/com.pzy.vibestick.helper"
    public static let launchDaemonPlistPath = "/Library/LaunchDaemons/com.pzy.vibestick.helper.plist"
    public static let helperStatePath = "/Library/Application Support/Vibestick/power-state.json"

    public static var userApplicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vibestick", isDirectory: true)
    }

    public static var userStatePath: URL {
        userApplicationSupportDirectory.appendingPathComponent("state.json")
    }

    public static var coderStatusDirectory: URL {
        userApplicationSupportDirectory.appendingPathComponent("coder-status", isDirectory: true)
    }

    public static var assertionMarkerPath: URL {
        userApplicationSupportDirectory.appendingPathComponent("hyper-assertion.json")
    }
}
