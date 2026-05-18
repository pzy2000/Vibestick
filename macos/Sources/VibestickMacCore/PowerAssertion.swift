import Foundation
import IOKit.pwr_mgt

public protocol SleepAssertionManaging: Sendable {
    func beginHyperAssertion() throws
    func endHyperAssertion()
    func isVibestickAssertionActive() -> Bool
}

public enum SleepAssertionError: Error, LocalizedError {
    case createFailed(IOReturn)

    public var errorDescription: String? {
        switch self {
        case .createFailed(let code):
            return "Could not create macOS power assertion. IOKit returned \(code)."
        }
    }
}

public final class MacSleepAssertionManager: SleepAssertionManaging, @unchecked Sendable {
    private let runner: CommandRunning
    private var assertionID = IOPMAssertionID(0)

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    deinit {
        endHyperAssertion()
    }

    public func beginHyperAssertion() throws {
        if assertionID != 0 {
            return
        }

        let reason = "Vibestick HYPER keep-awake" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID)

        if result != kIOReturnSuccess {
            assertionID = 0
            throw SleepAssertionError.createFailed(result)
        }
    }

    public func endHyperAssertion() {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
    }

    public func isVibestickAssertionActive() -> Bool {
        if assertionID != 0 {
            return true
        }

        guard let result = try? runner.runChecked("/usr/bin/pmset", ["-g", "assertions"]) else {
            return false
        }
        return result.standardOutput.localizedCaseInsensitiveContains("Vibestick HYPER")
    }
}
