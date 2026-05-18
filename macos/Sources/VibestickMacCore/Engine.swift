import Foundation

public final class VibestickMacEngine: @unchecked Sendable {
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

    public func applyMode(_ mode: VibestickMode) throws -> ModeChangeResult {
        switch mode {
        case .off:
            assertionManager.endHyperAssertion()
            return try helper.restore()
        case .on:
            assertionManager.endHyperAssertion()
            return try helper.applyOn()
        case .hyper:
            let result = try helper.applyHyper()
            try assertionManager.beginHyperAssertion()
            return result
        }
    }

    public func revert() throws -> ModeChangeResult {
        try applyMode(.off)
    }

    public func status() -> VibestickStatus {
        var warnings: [String] = []
        var snapshot: PmsetSnapshot?
        var mode: VibestickMode = .off
        var restorePending = false

        do {
            let helperStatus = try helper.status()
            snapshot = helperStatus.snapshot
            if let backup = helperStatus.backup {
                mode = backup.activeMode
                restorePending = true
            }
        } catch {
            warnings.append(error.localizedDescription)
        }

        let assertionActive = assertionManager.isVibestickAssertionActive()
        if assertionActive && mode != .hyper {
            mode = .hyper
        }

        return VibestickStatus(
            activeMode: mode,
            restorePending: restorePending,
            pmset: snapshot,
            battery: battery.getBatteryInfo(),
            longTasks: processInspector.getLongTasks(whitelist: options.longTaskProcessNames),
            assertionActive: assertionActive,
            warnings: warnings)
    }
}
