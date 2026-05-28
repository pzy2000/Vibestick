import Foundation

public enum AppInstallLocationKind: Equatable, Sendable {
    case systemApplications
    case userApplications
    case mountedVolume
    case other
}

public struct AppInstallLocation: Equatable, Sendable {
    public let appPath: String
    public let kind: AppInstallLocationKind

    public var canCompleteFirstLaunchInstall: Bool {
        kind == .systemApplications || kind == .userApplications
    }

    public init(appPath: String, homeDirectory: String = NSHomeDirectory()) {
        let standardizedPath = URL(fileURLWithPath: appPath).standardizedFileURL.path
        self.appPath = standardizedPath
        self.kind = Self.classify(appPath: standardizedPath, homeDirectory: homeDirectory)
    }

    private static func classify(appPath: String, homeDirectory: String) -> AppInstallLocationKind {
        if appPath.hasPrefix("/Volumes/") {
            return .mountedVolume
        }

        if appPath.hasPrefix("/Applications/"), appPath.hasSuffix(".app") {
            return .systemApplications
        }

        let userApplications = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
            .path
        if appPath.hasPrefix("\(userApplications)/"), appPath.hasSuffix(".app") {
            return .userApplications
        }

        return .other
    }
}

public struct FirstLaunchInstallStatus: Equatable, Sendable {
    public let location: AppInstallLocation
    public let helperPreflight: HelperInstallPreflight
    public let deviceWatcherStatus: DeviceWatcherInstallStatus

    public var needsHelperInstall: Bool {
        !helperPreflight.isInstalled
    }

    public var needsDeviceWatcherInstall: Bool {
        !deviceWatcherStatus.isInstalled
    }

    public var needsInstall: Bool {
        needsHelperInstall || needsDeviceWatcherInstall
    }

    public var canCompleteInstall: Bool {
        guard location.canCompleteFirstLaunchInstall else {
            return false
        }

        let helperReady = helperPreflight.isInstalled || helperPreflight.isReadyToInstall
        let deviceWatcherReady = deviceWatcherStatus.isInstalled || deviceWatcherStatus.isReadyToInstall
        return helperReady && deviceWatcherReady
    }

    public var missingComponentNames: [String] {
        var names: [String] = []
        if needsHelperInstall {
            names.append("Helper")
        }
        if needsDeviceWatcherInstall {
            names.append("插盘自启")
        }
        return names
    }
}

public struct FirstLaunchInstallResult: Equatable, Sendable {
    public let helperInstalled: Bool
    public let deviceWatcherInstalled: Bool

    public var didInstallAnything: Bool {
        helperInstalled || deviceWatcherInstalled
    }

    public var message: String {
        if helperInstalled && deviceWatcherInstalled {
            return "Helper 和插盘自启已完成安装。"
        }
        if helperInstalled {
            return "Helper 已完成安装，插盘自启已是最新状态。"
        }
        if deviceWatcherInstalled {
            return "插盘自启已完成安装，Helper 已是最新状态。"
        }
        return "Vibestick 安装已是最新状态。"
    }
}

public enum FirstLaunchInstallError: Error, LocalizedError, Equatable {
    case appNotInApplications(String)
    case installResourcesMissing(String)
    case helperFailed(String)
    case deviceWatcherFailed(String)

    public var errorDescription: String? {
        switch self {
        case .appNotInApplications(let path):
            if path.hasPrefix("/Volumes/") {
                return "请先把 Vibestick 拖到 Applications 后再打开，才能完成 Helper 和插盘自启安装。"
            }
            return "请先把 Vibestick.app 移到 Applications 后再完成安装。当前位置：\(path)"
        case .installResourcesMissing(let detail):
            return "安装资源缺失：\(detail)"
        case .helperFailed(let detail):
            return detail
        case .deviceWatcherFailed(let detail):
            return detail
        }
    }
}

public final class FirstLaunchInstaller: @unchecked Sendable {
    private let appPath: String
    private let homeDirectory: String
    private let helperInstaller: HelperInstalling
    private let deviceWatcherInstaller: DeviceWatcherInstalling

    public init(
        appPath: String,
        homeDirectory: String = NSHomeDirectory(),
        helperInstaller: HelperInstalling,
        deviceWatcherInstaller: DeviceWatcherInstalling
    ) {
        self.appPath = appPath
        self.homeDirectory = homeDirectory
        self.helperInstaller = helperInstaller
        self.deviceWatcherInstaller = deviceWatcherInstaller
    }

    public func status() -> FirstLaunchInstallStatus {
        FirstLaunchInstallStatus(
            location: AppInstallLocation(appPath: appPath, homeDirectory: homeDirectory),
            helperPreflight: helperInstaller.preflight(),
            deviceWatcherStatus: deviceWatcherInstaller.status())
    }

    public func completeInstall() throws -> FirstLaunchInstallResult {
        let currentStatus = status()
        guard currentStatus.location.canCompleteFirstLaunchInstall else {
            throw FirstLaunchInstallError.appNotInApplications(currentStatus.location.appPath)
        }

        var helperInstalled = false
        var deviceWatcherInstalled = false

        if currentStatus.needsHelperInstall {
            guard currentStatus.helperPreflight.isReadyToInstall else {
                throw FirstLaunchInstallError.installResourcesMissing("找不到 Helper 或 LaunchDaemon plist。")
            }

            do {
                _ = try helperInstaller.install()
                helperInstalled = true
            } catch {
                throw FirstLaunchInstallError.helperFailed(error.localizedDescription)
            }
        }

        let watcherStatus = deviceWatcherInstaller.status()
        if !watcherStatus.isInstalled {
            guard watcherStatus.isReadyToInstall else {
                throw FirstLaunchInstallError.installResourcesMissing("找不到 VibestickDeviceWatcher 或 Vibestick.app。")
            }

            do {
                _ = try deviceWatcherInstaller.install()
                deviceWatcherInstalled = true
            } catch {
                throw FirstLaunchInstallError.deviceWatcherFailed(error.localizedDescription)
            }
        }

        return FirstLaunchInstallResult(
            helperInstalled: helperInstalled,
            deviceWatcherInstalled: deviceWatcherInstalled)
    }
}
