import Foundation

public final class PetStateResolver: Sendable {
    public init() {}

    public func resolve(status: VibestickStatus, coders: [CoderAgentStatus]) -> PetState {
        let primary = coders.sorted { phasePriority($0.phase) < phasePriority($1.phase) }.first
        let activePrimary = coders
            .filter { Self.isActiveTaskPhase($0.phase) }
            .sorted { phasePriority($0.phase) < phasePriority($1.phase) }
            .first
        let mood = activePrimary.map { Self.mood(for: $0.phase) } ?? "idle"

        let title = primary?.taskSummary ?? primary?.agent ?? "Vibestick"
        let message = primary?.taskDetail ?? primary?.message ?? statusMessage(status)
        return PetState(mood: mood, title: title, message: message, coders: coders)
    }

    public static func isActiveTaskPhase(_ phase: CoderAgentPhase) -> Bool {
        switch phase {
        case .running, .reasoning, .toolCalling:
            true
        case .idle, .sleeping, .waitingAuthorization, .error, .success, .offline, .unknown:
            false
        }
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
        case .idle, .sleeping, .waitingAuthorization, .error, .success, .offline, .unknown:
            "idle"
        }
    }
}
