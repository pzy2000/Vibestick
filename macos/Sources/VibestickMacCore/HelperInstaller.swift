import Foundation

public struct HelperInstallPaths: Equatable, Sendable {
    public let sourceHelperPath: String
    public let sourcePlistPath: String
    public let installedHelperPath: String
    public let installedPlistPath: String

    public init(
        sourceHelperPath: String,
        sourcePlistPath: String,
        installedHelperPath: String = VibestickPaths.installedHelperPath,
        installedPlistPath: String = VibestickPaths.launchDaemonPlistPath
    ) {
        self.sourceHelperPath = sourceHelperPath
        self.sourcePlistPath = sourcePlistPath
        self.installedHelperPath = installedHelperPath
        self.installedPlistPath = installedPlistPath
    }

    public static func resolvedDefault() -> HelperInstallPaths {
        let environment = ProcessInfo.processInfo.environment
        let appBundle = Bundle.main.bundleURL
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
            .standardized
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)

        let bundledHelper = appBundle
            .appendingPathComponent("Contents/Library/PrivilegedHelperTools/\(VibestickPaths.helperIdentifier)")
            .path
        let bundledPlist = appBundle
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(VibestickPaths.helperIdentifier).plist")
            .path
        let localPlistCandidates = [
            currentDirectory.appendingPathComponent("packaging/LaunchDaemons/\(VibestickPaths.helperIdentifier).plist").path,
            currentDirectory.appendingPathComponent("macos/packaging/LaunchDaemons/\(VibestickPaths.helperIdentifier).plist").path
        ]

        let sourceHelper = environment["VIBESTICK_HELPER_SOURCE_PATH"]
            ?? (appBundle.pathExtension == "app" ? bundledHelper : executableDirectory.appendingPathComponent("VibestickHelper").path)
        let sourcePlist = environment["VIBESTICK_HELPER_PLIST_SOURCE_PATH"]
            ?? (appBundle.pathExtension == "app" ? bundledPlist : localPlistCandidates.first { FileManager.default.fileExists(atPath: $0) } ?? bundledPlist)

        return HelperInstallPaths(sourceHelperPath: sourceHelper, sourcePlistPath: sourcePlist)
    }
}

public struct HelperInstallPreflight: Equatable, Sendable {
    public let sourceHelperExists: Bool
    public let sourcePlistExists: Bool
    public let helperInstalled: Bool
    public let plistInstalled: Bool

    public var isReadyToInstall: Bool {
        sourceHelperExists && sourcePlistExists
    }

    public var isInstalled: Bool {
        helperInstalled && plistInstalled
    }
}

public struct HelperInstallResult: Equatable, Sendable {
    public let installedHelperPath: String
    public let installedPlistPath: String
    public let message: String
    public let detail: String
}

public protocol HelperInstalling: Sendable {
    var paths: HelperInstallPaths { get }
    func preflight() -> HelperInstallPreflight
    func install() throws -> HelperInstallResult
}

public enum HelperInstallError: Error, LocalizedError, Equatable {
    case missingSourceHelper(String)
    case missingSourcePlist(String)
    case stagingFailed(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingSourceHelper(let path):
            return "找不到可安装的 Helper：\(path)。请先运行 macos/scripts/build-release.sh dev 或 swift build -c release。"
        case .missingSourcePlist(let path):
            return "找不到 Helper 的 LaunchDaemon plist：\(path)。请确认 macOS 打包资源完整。"
        case .stagingFailed(let detail):
            return "Helper 安装准备失败：\(detail)"
        case .installFailed(let detail):
            if detail.localizedCaseInsensitiveContains("user canceled") || detail.contains("-128") {
                return "Helper 安装已取消。"
            }
            if detail.localizedCaseInsensitiveContains("operation not permitted") {
                return "Helper 安装失败：macOS 拒绝读取安装文件。Vibestick 会先把安装文件暂存到 /private/tmp 后再提权安装；请重新构建后重试。详细信息：\(detail)"
            }
            return "Helper 安装失败：\(detail)"
        }
    }
}

public final class MacHelperInstaller: HelperInstalling, @unchecked Sendable {
    public let paths: HelperInstallPaths
    private let runner: CommandRunning
    private let fileManager: FileManager

    public init(
        paths: HelperInstallPaths = .resolvedDefault(),
        runner: CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.runner = runner
        self.fileManager = fileManager
    }

    public func preflight() -> HelperInstallPreflight {
        HelperInstallPreflight(
            sourceHelperExists: fileManager.isExecutableFile(atPath: paths.sourceHelperPath),
            sourcePlistExists: fileManager.fileExists(atPath: paths.sourcePlistPath),
            helperInstalled: fileManager.isExecutableFile(atPath: paths.installedHelperPath),
            plistInstalled: fileManager.fileExists(atPath: paths.installedPlistPath))
    }

    public func install() throws -> HelperInstallResult {
        let preflight = preflight()
        guard preflight.sourceHelperExists else {
            throw HelperInstallError.missingSourceHelper(paths.sourceHelperPath)
        }
        guard preflight.sourcePlistExists else {
            throw HelperInstallError.missingSourcePlist(paths.sourcePlistPath)
        }

        let stagedPaths = try stageInstallFiles()
        defer {
            try? fileManager.removeItem(atPath: URL(fileURLWithPath: stagedPaths.sourceHelperPath).deletingLastPathComponent().path)
        }

        let script = Self.buildInstallShellScript(paths: stagedPaths)
        let appleScript = "do shell script \"\(Self.escapeAppleScriptString(script))\" with administrator privileges"

        do {
            let result = try runner.runChecked("/usr/bin/osascript", ["-e", appleScript])
            return HelperInstallResult(
                installedHelperPath: paths.installedHelperPath,
                installedPlistPath: paths.installedPlistPath,
                message: "Helper 已安装并启动。",
                detail: result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch CommandRunError.nonZero(let result) {
            throw HelperInstallError.installFailed(Self.formatCommandFailure(result))
        } catch {
            throw HelperInstallError.installFailed(error.localizedDescription)
        }
    }

    static func buildInstallShellScript(paths: HelperInstallPaths) -> String {
        [
            "set -e",
            "install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools",
            "install -o root -g wheel -m 755 \(shellQuote(paths.sourceHelperPath)) \(shellQuote(paths.installedHelperPath))",
            "install -o root -g wheel -m 644 \(shellQuote(paths.sourcePlistPath)) \(shellQuote(paths.installedPlistPath))",
            "if launchctl print system/\(shellQuote(VibestickPaths.helperIdentifier)) >/dev/null 2>&1; then launchctl bootout system \(shellQuote(paths.installedPlistPath)) || true; fi",
            "launchctl bootstrap system \(shellQuote(paths.installedPlistPath))",
            "launchctl enable system/\(shellQuote(VibestickPaths.helperIdentifier))"
        ].joined(separator: "; ")
    }

    private func stageInstallFiles() throws -> HelperInstallPaths {
        let stageDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("VibestickHelperInstall-\(UUID().uuidString)", isDirectory: true)
        let stagedHelper = stageDirectory.appendingPathComponent(VibestickPaths.helperIdentifier)
        let stagedPlist = stageDirectory.appendingPathComponent("\(VibestickPaths.helperIdentifier).plist")

        do {
            try fileManager.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stageDirectory.path)
            try fileManager.copyItem(atPath: paths.sourceHelperPath, toPath: stagedHelper.path)
            try fileManager.copyItem(atPath: paths.sourcePlistPath, toPath: stagedPlist.path)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedHelper.path)
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stagedPlist.path)
        } catch {
            try? fileManager.removeItem(at: stageDirectory)
            throw HelperInstallError.stagingFailed(error.localizedDescription)
        }

        return HelperInstallPaths(
            sourceHelperPath: stagedHelper.path,
            sourcePlistPath: stagedPlist.path,
            installedHelperPath: paths.installedHelperPath,
            installedPlistPath: paths.installedPlistPath)
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func formatCommandFailure(_ result: CommandResult) -> String {
        [result.standardOutput, result.standardError]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
