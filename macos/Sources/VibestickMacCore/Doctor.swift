import Foundation

public final class MacDoctorService: @unchecked Sendable {
    private let helper: HelperClienting
    private let battery: BatteryMonitoring
    private let processInspector: ProcessInspecting
    private let assertionManager: SleepAssertionManaging
    private let options: VibestickOptions

    public init(
        helper: HelperClienting,
        battery: BatteryMonitoring,
        processInspector: ProcessInspecting,
        assertionManager: SleepAssertionManaging,
        options: VibestickOptions = VibestickOptions()
    ) {
        self.helper = helper
        self.battery = battery
        self.processInspector = processInspector
        self.assertionManager = assertionManager
        self.options = options
    }

    public func run() -> DoctorReport {
        var checks: [DoctorCheck] = []
        checks.append(DoctorCheck("os", ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14, "macOS detected."))
        checks.append(DoctorCheck(
            "helper",
            FileManager.default.isExecutableFile(atPath: helper.helperPath) || helper.helperPath == "direct",
            "Helper path: \(helper.helperPath)"))

        do {
            let status = try helper.status()
            checks.append(DoctorCheck("helper-client", status.ok, status.message ?? "Helper communication is available."))
            checks.append(DoctorCheck("pmset", status.snapshot != nil, formatPmset(status.snapshot)))
            checks.append(DoctorCheck("state", true, status.backup == nil ? "No restore is pending." : "Restore state path: \(status.statePath)"))
        } catch {
            checks.append(DoctorCheck("helper-client", false, error.localizedDescription))
            checks.append(DoctorCheck("pmset", false, "pmset status is unavailable."))
            checks.append(DoctorCheck("state", false, "Power state is unavailable."))
        }

        let batteryInfo = battery.getBatteryInfo()
        checks.append(DoctorCheck(
            "battery",
            batteryInfo.isAvailable,
            batteryInfo.isAvailable
                ? "Battery \(batteryInfo.percentage.map { "\($0)%" } ?? "unknown"); AC connected=\(batteryInfo.isACConnected)."
                : "Battery status is unavailable."))
        checks.append(DoctorCheck(
            "assertion",
            true,
            assertionManager.isVibestickAssertionActive() ? "Vibestick HYPER assertion is active." : "No Vibestick HYPER assertion is active."))
        checks.append(DoctorCheck(
            "accessibility",
            AccessibilityStatus.isTrusted(prompt: false),
            AccessibilityStatus.isTrusted(prompt: false)
                ? "Accessibility permission is granted."
                : "Accessibility permission is not granted."))

        let longTasks = processInspector.getLongTasks(whitelist: options.longTaskProcessNames)
        checks.append(DoctorCheck(
            "long-tasks",
            true,
            longTasks.isEmpty ? "No whitelisted coder tasks detected." : "Detected: \(longTasks.map(\.name).joined(separator: ", "))."))

        return DoctorReport(checks: checks)
    }

    private func formatPmset(_ snapshot: PmsetSnapshot?) -> String {
        guard let snapshot else {
            return "pmset snapshot unavailable."
        }
        let batterySleep = snapshot.value("sleep", source: .battery) ?? "-"
        let acSleep = snapshot.value("sleep", source: .ac) ?? "-"
        return "sleep battery=\(batterySleep), ac=\(acSleep)."
    }
}
