import Foundation

public protocol BatteryMonitoring: Sendable {
    func getBatteryInfo() -> BatteryInfo
}

public final class MacBatteryMonitor: BatteryMonitoring, @unchecked Sendable {
    private let runner: CommandRunning

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func getBatteryInfo() -> BatteryInfo {
        guard let result = try? runner.runChecked("/usr/bin/pmset", ["-g", "batt"]) else {
            return BatteryInfo(percentage: nil, isACConnected: false, isAvailable: false)
        }

        return Self.parsePmsetBattery(result.standardOutput)
    }

    public static func parsePmsetBattery(_ text: String) -> BatteryInfo {
        let isAC = text.contains("AC Power")
        let isBattery = text.contains("Battery Power")
        guard let percentRange = text.range(of: #"(\d+)%"#, options: .regularExpression) else {
            return BatteryInfo(percentage: nil, isACConnected: isAC, isAvailable: isAC || isBattery)
        }

        let percentText = String(text[percentRange]).trimmingCharacters(in: CharacterSet(charactersIn: "%"))
        return BatteryInfo(
            percentage: Int(percentText),
            isACConnected: isAC,
            isAvailable: true)
    }
}
