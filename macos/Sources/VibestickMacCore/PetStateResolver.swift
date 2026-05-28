import Foundation

public final class PetStateResolver: Sendable {
    private static let lowBatteryThreshold = 20

    public init() {}

    public func resolve(status: VibestickStatus, coders: [CoderAgentStatus]) -> PetState {
        let primary = coders.sorted { phasePriority($0.phase) < phasePriority($1.phase) }.first
        let mood: String
        if status.activeMode == .hyper {
            mood = "power"
        } else if let primary {
            mood = Self.mood(for: primary.phase)
        } else if Self.isLowBattery(status.battery) {
            mood = "low_battery"
        } else {
            mood = "idle"
        }

        let title = primary?.taskSummary ?? primary?.agent ?? "Vibestick"
        let message = primary?.taskDetail ?? primary?.message ?? statusMessage(status)
        return PetState(mood: mood, title: title, message: message, coders: coders)
    }

    private func statusMessage(_ status: VibestickStatus) -> String {
        switch status.activeMode {
        case .off: "Normal Mac sleep policy is active."
        case .on: "Mac sleep policy is controlled by Vibestick."
        case .hyper: "HYPER is keeping wake priority."
        }
    }

    private static func mood(for phase: CoderAgentPhase) -> String {
        switch phase {
        case .running: "running"
        case .toolCalling: "tool_calling"
        case .reasoning: "reasoning"
        case .waitingAuthorization: "waiting"
        case .error: "error"
        case .success: "success"
        case .offline: "offline"
        case .sleeping: "sleeping"
        case .idle, .unknown: "idle"
        }
    }

    private static func isLowBattery(_ battery: BatteryInfo) -> Bool {
        guard battery.isAvailable,
              !battery.isACConnected,
              let percentage = battery.percentage
        else {
            return false
        }
        return percentage <= lowBatteryThreshold
    }
}
