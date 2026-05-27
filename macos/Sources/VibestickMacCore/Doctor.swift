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
        checks.append(DoctorCheck("os", ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14, "已检测到 macOS。"))
        let helperAvailable = FileManager.default.isExecutableFile(atPath: helper.helperPath) || helper.helperPath == "direct"
        checks.append(DoctorCheck(
            "helper",
            helperAvailable,
            helperAvailable
                ? "Helper 已安装或已指定：\(helper.helperPath)"
                : "Helper 未安装或不可执行：\(helper.helperPath)。请点击“安装 Helper”。"))

        do {
            let status = try helper.status()
            checks.append(DoctorCheck("helper-client", status.ok, status.message ?? "Helper 通信正常。"))
            checks.append(DoctorCheck("pmset", status.snapshot != nil, formatPmset(status.snapshot)))
            checks.append(DoctorCheck("state", true, status.backup == nil ? "没有待恢复的睡眠策略备份。" : "待恢复状态文件：\(status.statePath)"))
        } catch {
            checks.append(DoctorCheck("helper-client", false, error.localizedDescription))
            checks.append(DoctorCheck("pmset", false, "无法读取 pmset 状态；请先安装并启动 Helper。"))
            checks.append(DoctorCheck("state", false, "无法读取电源策略备份状态。"))
        }

        let batteryInfo = battery.getBatteryInfo()
        checks.append(DoctorCheck(
            "battery",
            batteryInfo.isAvailable,
            batteryInfo.isAvailable
                ? "电池 \(batteryInfo.percentage.map { "\($0)%" } ?? "未知")；外接电源=\(batteryInfo.isACConnected ? "是" : "否")。"
                : "无法读取电池状态。"))
        checks.append(DoctorCheck(
            "assertion",
            true,
            assertionManager.isVibestickAssertionActive() ? "Vibestick HYPER assertion 正在生效。" : "当前没有 Vibestick HYPER assertion。"))
        checks.append(DoctorCheck(
            "accessibility",
            AccessibilityStatus.isTrusted(prompt: false),
            AccessibilityStatus.isTrusted(prompt: false)
                ? "辅助功能权限已授权。"
                : "辅助功能权限尚未授权。"))

        let longTasks = processInspector.getLongTasks(whitelist: options.longTaskProcessNames)
        checks.append(DoctorCheck(
            "long-tasks",
            true,
            longTasks.isEmpty ? "没有检测到白名单内的 coder 任务。" : "检测到：\(longTasks.map(\.name).joined(separator: ", "))。"))

        return DoctorReport(checks: checks)
    }

    private func formatPmset(_ snapshot: PmsetSnapshot?) -> String {
        guard let snapshot else {
            return "无法读取 pmset 快照。"
        }
        let batterySleep = snapshot.value("sleep", source: .battery) ?? "-"
        let acSleep = snapshot.value("sleep", source: .ac) ?? "-"
        return "sleep 电池=\(batterySleep)，外接电源=\(acSleep)。"
    }
}
