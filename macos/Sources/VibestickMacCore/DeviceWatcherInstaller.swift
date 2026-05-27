import Foundation

public struct DeviceWatcherInstallPaths: Equatable, Sendable {
    public let watcherExecutablePath: String
    public let appPath: String
    public let plistPath: String
    public let logPath: String
    public let errorLogPath: String

    public init(
        watcherExecutablePath: String,
        appPath: String,
        plistPath: String = VibestickPaths.deviceWatcherLaunchAgentPlistPath.path,
        logPath: String = VibestickPaths.deviceWatcherLogPath.path,
        errorLogPath: String = VibestickPaths.deviceWatcherErrorLogPath.path
    ) {
        self.watcherExecutablePath = watcherExecutablePath
        self.appPath = appPath
        self.plistPath = plistPath
        self.logPath = logPath
        self.errorLogPath = errorLogPath
    }

    public static func resolvedDefault(appPath configuredAppPath: String? = nil) -> DeviceWatcherInstallPaths {
        let environment = ProcessInfo.processInfo.environment
        let appBundle = Bundle.main.bundleURL
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
            .standardized
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let appPath = configuredAppPath
            ?? environment["VIBESTICK_APP_PATH"]
            ?? Self.defaultAppPath(appBundle: appBundle, currentDirectory: currentDirectory)
        let appWatcher = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/MacOS/VibestickDeviceWatcher")
            .path

        let bundledWatcher = appBundle
            .appendingPathComponent("Contents/MacOS/VibestickDeviceWatcher")
            .path
        let sourceWatcher = environment["VIBESTICK_DEVICE_WATCHER_PATH"]
            ?? (appBundle.pathExtension == "app"
                ? bundledWatcher
                : (FileManager.default.fileExists(atPath: appWatcher)
                    ? appWatcher
                    : executableDirectory.appendingPathComponent("VibestickDeviceWatcher").path))

        return DeviceWatcherInstallPaths(watcherExecutablePath: sourceWatcher, appPath: appPath)
    }

    private static func defaultAppPath(appBundle: URL, currentDirectory: URL) -> String {
        if appBundle.pathExtension == "app" {
            return appBundle.path
        }

        let candidates = [
            currentDirectory.appendingPathComponent("dist/Vibestick.app").path,
            currentDirectory.appendingPathComponent("macos/dist/Vibestick.app").path,
            "/Applications/Vibestick.app"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/Applications/Vibestick.app"
    }
}

public struct DeviceWatcherInstallStatus: Codable, Equatable, Sendable {
    public let watcherExecutablePath: String
    public let appPath: String
    public let plistPath: String
    public let watcherExecutableExists: Bool
    public let appExists: Bool
    public let plistInstalled: Bool
    public let launchAgentLoaded: Bool

    public var isReadyToInstall: Bool {
        watcherExecutableExists && appExists
    }

    public var isInstalled: Bool {
        plistInstalled && launchAgentLoaded
    }
}

public struct DeviceWatcherInstallResult: Codable, Equatable, Sendable {
    public let plistPath: String
    public let watcherExecutablePath: String
    public let appPath: String
    public let message: String
}

public protocol DeviceWatcherInstalling: Sendable {
    var paths: DeviceWatcherInstallPaths { get }
    func status() -> DeviceWatcherInstallStatus
    func install() throws -> DeviceWatcherInstallResult
    func uninstall() throws -> DeviceWatcherInstallResult
}

public enum DeviceWatcherInstallError: Error, LocalizedError, Equatable {
    case missingWatcherExecutable(String)
    case missingApp(String)
    case plistWriteFailed(String)
    case launchctlFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingWatcherExecutable(let path):
            return "找不到 VibestickDeviceWatcher：\(path)。请先重新构建 macOS app。"
        case .missingApp(let path):
            return "找不到 Vibestick.app：\(path)。请先运行 macos/scripts/build-release.sh dev 或传入 --app-path。"
        case .plistWriteFailed(let detail):
            return "LaunchAgent 写入失败：\(detail)"
        case .launchctlFailed(let detail):
            return "LaunchAgent 注册失败：\(detail)"
        }
    }
}

public final class MacDeviceWatcherInstaller: DeviceWatcherInstalling, @unchecked Sendable {
    public let paths: DeviceWatcherInstallPaths
    private let runner: CommandRunning
    private let fileManager: FileManager
    private let userId: UInt32

    public init(
        paths: DeviceWatcherInstallPaths = .resolvedDefault(),
        runner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        userId: UInt32 = getuid()
    ) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
        self.userId = userId
    }

    public func status() -> DeviceWatcherInstallStatus {
        DeviceWatcherInstallStatus(
            watcherExecutablePath: paths.watcherExecutablePath,
            appPath: paths.appPath,
            plistPath: paths.plistPath,
            watcherExecutableExists: fileManager.isExecutableFile(atPath: paths.watcherExecutablePath),
            appExists: fileManager.fileExists(atPath: paths.appPath),
            plistInstalled: fileManager.fileExists(atPath: paths.plistPath),
            launchAgentLoaded: isLoaded())
    }

    public func install() throws -> DeviceWatcherInstallResult {
        guard fileManager.isExecutableFile(atPath: paths.watcherExecutablePath) else {
            throw DeviceWatcherInstallError.missingWatcherExecutable(paths.watcherExecutablePath)
        }
        guard fileManager.fileExists(atPath: paths.appPath) else {
            throw DeviceWatcherInstallError.missingApp(paths.appPath)
        }

        do {
            let plistURL = URL(fileURLWithPath: paths.plistPath)
            try fileManager.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Self.buildLaunchAgentPlist(paths: paths).write(to: plistURL, options: .atomic)
        } catch {
            throw DeviceWatcherInstallError.plistWriteFailed(error.localizedDescription)
        }

        if isLoaded() {
            _ = try? runner.run("/bin/launchctl", ["bootout", launchDomain, paths.plistPath])
        }

        do {
            _ = try runner.runChecked("/bin/launchctl", ["bootstrap", launchDomain, paths.plistPath])
            _ = try runner.runChecked("/bin/launchctl", ["enable", "\(launchDomain)/\(VibestickPaths.deviceWatcherIdentifier)"])
        } catch CommandRunError.nonZero(let result) {
            throw DeviceWatcherInstallError.launchctlFailed(Self.formatCommandFailure(result))
        } catch {
            throw DeviceWatcherInstallError.launchctlFailed(error.localizedDescription)
        }

        return DeviceWatcherInstallResult(
            plistPath: paths.plistPath,
            watcherExecutablePath: paths.watcherExecutablePath,
            appPath: paths.appPath,
            message: "插盘自启 LaunchAgent 已安装并启动。")
    }

    public func uninstall() throws -> DeviceWatcherInstallResult {
        if isLoaded() {
            do {
                _ = try runner.runChecked("/bin/launchctl", ["bootout", launchDomain, paths.plistPath])
            } catch CommandRunError.nonZero(let result) {
                throw DeviceWatcherInstallError.launchctlFailed(Self.formatCommandFailure(result))
            } catch {
                throw DeviceWatcherInstallError.launchctlFailed(error.localizedDescription)
            }
        }

        do {
            if fileManager.fileExists(atPath: paths.plistPath) {
                try fileManager.removeItem(atPath: paths.plistPath)
            }
        } catch {
            throw DeviceWatcherInstallError.plistWriteFailed(error.localizedDescription)
        }

        return DeviceWatcherInstallResult(
            plistPath: paths.plistPath,
            watcherExecutablePath: paths.watcherExecutablePath,
            appPath: paths.appPath,
            message: "插盘自启 LaunchAgent 已卸载。")
    }

    public static func buildLaunchAgentPlist(paths: DeviceWatcherInstallPaths) throws -> Data {
        let plist: [String: Any] = [
            "Label": VibestickPaths.deviceWatcherIdentifier,
            "ProgramArguments": [
                paths.watcherExecutablePath,
                "--app-path",
                paths.appPath
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": paths.logPath,
            "StandardErrorPath": paths.errorLogPath
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private var launchDomain: String {
        "gui/\(userId)"
    }

    private func isLoaded() -> Bool {
        (try? runner.run("/bin/launchctl", ["print", "\(launchDomain)/\(VibestickPaths.deviceWatcherIdentifier)"]).exitCode) == 0
    }

    private static func formatCommandFailure(_ result: CommandResult) -> String {
        [result.standardOutput, result.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
