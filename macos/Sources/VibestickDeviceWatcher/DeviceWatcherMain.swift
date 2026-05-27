import Foundation
import VibestickMacCore

@main
private enum DeviceWatcherMain {
    static let args = Array(CommandLine.arguments.dropFirst())

    static func main() {
        if hasFlag("--help") || hasFlag("-h") {
            printHelp()
            exit(0)
        }

        let once = hasFlag("--once")
        let noLaunch = hasFlag("--no-launch")
        let log = DeviceWatcherLog(path: option("--log-path").map { URL(fileURLWithPath: $0) } ?? VibestickPaths.deviceWatcherLogPath)
        let options = VibestickDeviceOptions()
        let source = MacUSBDeviceSnapshotSource(options: options)
        let policy = DeviceAutoLaunchPolicy(debounce: options.launchDebounce)
        let appPath = resolveAppPath(option("--app-path"))
        let launcher = VibestickAppLauncher(appPath: appPath, noLaunch: noLaunch)
        let evaluator = WatcherEvaluator(source: source, policy: policy, launcher: launcher, log: log)

        log.write("Vibestick device watcher started.")
        log.write("App path: \(appPath)")

        _ = evaluator.evaluate()

        if once {
            exit(0)
        }

        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        signalSource.setEventHandler {
            log.write("Vibestick device watcher stopped.")
            exit(0)
        }
        signalSource.resume()

        if let token = source.startAttachNotifications(queue: .main, handler: {
            _ = evaluator.evaluate()
        }) {
            log.write("IOKit USB attach notifications registered.")
            withExtendedLifetime(token) {
                RunLoop.main.run()
            }
        } else {
            log.write("IOKit USB attach notifications unavailable; falling back to polling.")
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                _ = evaluator.evaluate()
            }
            RunLoop.main.add(timer, forMode: .default)
            RunLoop.main.run()
        }
    }
}

private final class WatcherEvaluator: @unchecked Sendable {
    private let source: MacUSBDeviceSnapshotSource
    private let policy: DeviceAutoLaunchPolicy
    private let launcher: VibestickAppLauncher
    private let log: DeviceWatcherLog
    private var lastStatus: String?

    init(
        source: MacUSBDeviceSnapshotSource,
        policy: DeviceAutoLaunchPolicy,
        launcher: VibestickAppLauncher,
        log: DeviceWatcherLog
    ) {
        self.source = source
        self.policy = policy
        self.launcher = launcher
        self.log = log
    }

    func evaluate() -> DeviceDetectionResult {
        let detection = DeviceDetector.detect(source.getSnapshots())
        let decision = policy.evaluate(
            detection: detection,
            isGuiAlreadyRunning: launcher.isGuiRunning(),
            now: Date())
        let status = "\(detection.kind.rawValue): \(decision.action.rawValue): \(decision.message)"
        if status != lastStatus {
            log.write(status)
            lastStatus = status
        }

        if decision.action == .launch {
            let result = launcher.launchOrFocus()
            log.write("\(result.action.rawValue): \(result.message)")
        }

        return detection
    }
}

private final class DeviceWatcherLog {
    private let path: URL
    private let fileManager: FileManager

    init(path: URL, fileManager: FileManager = .default) {
        self.path = path
        self.fileManager = fileManager
    }

    func write(_ message: String) {
        do {
            try fileManager.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if fileManager.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: path, atomically: true, encoding: .utf8)
            }
        } catch {
        }
    }
}

private func resolveAppPath(_ configuredPath: String?) -> String {
    if let configuredPath, !configuredPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return URL(fileURLWithPath: configuredPath).standardized.path
    }

    let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").standardized
    let candidateBundle = executable
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    if candidateBundle.pathExtension == "app" {
        return candidateBundle.path
    }

    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let candidates = [
        currentDirectory.appendingPathComponent("dist/Vibestick.app"),
        currentDirectory.appendingPathComponent("macos/dist/Vibestick.app"),
        URL(fileURLWithPath: "/Applications/Vibestick.app")
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }?.path ?? "/Applications/Vibestick.app"
}

private func hasFlag(_ flag: String) -> Bool {
    DeviceWatcherMain.args.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
}

private func option(_ name: String) -> String? {
    let args = DeviceWatcherMain.args
    for index in 0..<(args.count - 1) where args[index].caseInsensitiveCompare(name) == .orderedSame {
        return args[index + 1]
    }
    return nil
}

private func printHelp() {
    print("""
    Vibestick Device Watcher

    Usage:
      VibestickDeviceWatcher [--app-path <path>] [--once] [--no-launch] [--log-path <path>]
    """)
}
