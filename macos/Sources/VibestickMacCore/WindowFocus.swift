import AppKit
import Foundation

@MainActor
public enum WindowFocusService {
    public static func tryFocusCoderWindow(_ status: CoderAgentStatus?) -> Bool {
        guard AccessibilityStatus.isTrusted(prompt: false) else {
            return false
        }

        let workspaceName = status?.workspace.flatMap { URL(fileURLWithPath: $0).lastPathComponent }
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard let name = app.localizedName else {
                return false
            }
            return ["Codex", "Cursor", "Code", "VSCodium"].contains { name.localizedCaseInsensitiveContains($0) }
        }

        if let workspaceName,
           let app = candidates.first(where: { $0.localizedName?.localizedCaseInsensitiveContains(workspaceName) == true }) {
            return app.activate(options: [.activateAllWindows])
        }

        if let app = candidates.first {
            return app.activate(options: [.activateAllWindows])
        }

        return false
    }
}
