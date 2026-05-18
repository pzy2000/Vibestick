import Foundation

public final class PetStateResolver: Sendable {
    public init() {}

    public func resolve(status: VibestickStatus, coders: [CoderAgentStatus]) -> PetState {
        let primary = coders.sorted { phasePriority($0.phase) < phasePriority($1.phase) }.first
        let mood: String
        if status.activeMode == .hyper {
            mood = "power"
        } else if let primary {
            mood = Self.mood(for: primary.phase)
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
        case .running, .toolCalling: "running"
        case .reasoning: "reasoning"
        case .waitingAuthorization: "waiting"
        case .error: "error"
        case .success: "success"
        case .offline: "offline"
        case .sleeping: "sleeping"
        case .idle, .unknown: "idle"
        }
    }
}
