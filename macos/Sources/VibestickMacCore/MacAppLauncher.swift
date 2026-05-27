import AppKit
import Foundation

public protocol MacApplicationControlling: Sendable {
    func isApplicationRunning(bundleIdentifier: String) -> Bool
    func activateApplication(bundleIdentifier: String) -> Bool
    func openApplication(at appPath: String, arguments: [String]) throws
}

public enum MacAppLaunchError: Error, LocalizedError, Equatable {
    case openTimedOut(String)
    case openFailed(String)

    public var errorDescription: String? {
        switch self {
        case .openTimedOut(let path):
            return "Timed out while opening \(path)."
        case .openFailed(let message):
            return message
        }
    }
}

public final class NSWorkspaceApplicationController: MacApplicationControlling, @unchecked Sendable {
    public init() {}

    public func isApplicationRunning(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }
    }

    public func activateApplication(bundleIdentifier: String) -> Bool {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
        }) else {
            return false
        }

        return app.activate(options: [.activateAllWindows])
    }

    public func openApplication(at appPath: String, arguments: [String]) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = MacOpenApplicationResultBox()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appPath), configuration: configuration) { app, error in
            resultBox.set(opened: app != nil, error: error)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 15) == .success else {
            throw MacAppLaunchError.openTimedOut(appPath)
        }
        let result = resultBox.get()
        if let openError = result.error {
            throw MacAppLaunchError.openFailed(openError.localizedDescription)
        }
        if !result.opened {
            throw MacAppLaunchError.openFailed("macOS did not return a running Vibestick application.")
        }
    }
}

private final class MacOpenApplicationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var error: Error?

    func set(opened: Bool, error: Error?) {
        lock.lock()
        self.opened = opened
        self.error = error
        lock.unlock()
    }

    func get() -> (opened: Bool, error: Error?) {
        lock.lock()
        defer {
            lock.unlock()
        }
        return (opened, error)
    }
}

public enum VibestickAppLaunchAction: String, Codable, Sendable {
    case focused
    case opened
    case suppressed
    case missingApp
    case failed
}

public struct VibestickAppLaunchResult: Codable, Equatable, Sendable {
    public let action: VibestickAppLaunchAction
    public let message: String
}

public final class VibestickAppLauncher: @unchecked Sendable {
    private let appPath: String
    private let bundleIdentifier: String
    private let noLaunch: Bool
    private let controller: MacApplicationControlling
    private let fileManager: FileManager

    public init(
        appPath: String,
        bundleIdentifier: String = VibestickPaths.bundleIdentifier,
        noLaunch: Bool = false,
        controller: MacApplicationControlling = NSWorkspaceApplicationController(),
        fileManager: FileManager = .default
    ) {
        self.appPath = appPath
        self.bundleIdentifier = bundleIdentifier
        self.noLaunch = noLaunch
        self.controller = controller
        self.fileManager = fileManager
    }

    public func isGuiRunning() -> Bool {
        controller.isApplicationRunning(bundleIdentifier: bundleIdentifier)
    }

    public func launchOrFocus() -> VibestickAppLaunchResult {
        if noLaunch {
            return VibestickAppLaunchResult(action: .suppressed, message: "Launch suppressed by --no-launch.")
        }

        if controller.isApplicationRunning(bundleIdentifier: bundleIdentifier) {
            if controller.activateApplication(bundleIdentifier: bundleIdentifier) {
                return VibestickAppLaunchResult(action: .focused, message: "Vibestick app focused.")
            }
            return VibestickAppLaunchResult(action: .failed, message: "Vibestick app is running but could not be focused.")
        }

        guard fileManager.fileExists(atPath: appPath) else {
            return VibestickAppLaunchResult(action: .missingApp, message: "Vibestick app not found: \(appPath)")
        }

        do {
            try controller.openApplication(at: appPath, arguments: ["--device-auto-start"])
            return VibestickAppLaunchResult(action: .opened, message: "Vibestick app launch requested.")
        } catch {
            return VibestickAppLaunchResult(action: .failed, message: error.localizedDescription)
        }
    }
}
