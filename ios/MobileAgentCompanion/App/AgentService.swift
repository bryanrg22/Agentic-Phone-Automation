import ActivityKit
import Foundation
import Observation

@Observable
class AgentService {
    var serverURL: String = ""
    var isPolling: Bool = false
    var currentState: AgentStatusResponse?

    private var pollingTask: Task<Void, Never>?
    private var currentActivity: Activity<AgentActivityAttributes>?
    private var wasActive: Bool = false

    struct AgentStatusResponse: Codable {
        let isActive: Bool
        let taskName: String
        let currentStep: Int
        let totalSteps: Int
        let thought: String
        let phase: String
        let toolName: String
        let elapsed: String
        let isComplete: Bool
        let success: Bool
    }

    func startPolling() {
        guard !serverURL.isEmpty else { return }
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll() async {
        guard let url = URL(string: "\(serverURL)/status") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONDecoder().decode(AgentStatusResponse.self, from: data)

            await MainActor.run {
                self.currentState = status
                self.handleStatusUpdate(status)
            }
        } catch {
            // Server not responding — that's okay, keep polling
        }
    }

    private func handleStatusUpdate(_ status: AgentStatusResponse) {
        if status.isActive && !wasActive {
            // Agent just started — create Live Activity
            startLiveActivity(taskName: status.taskName)
            wasActive = true
        }

        if status.isActive {
            updateLiveActivity(status)
        }

        if status.isComplete && wasActive {
            endLiveActivity(success: status.success)
            wasActive = false
        }

        if !status.isActive && !status.isComplete {
            wasActive = false
        }
    }

    private func startLiveActivity(taskName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("Live Activities not enabled")
            return
        }

        let attributes = AgentActivityAttributes(taskName: taskName)
        let initialState = AgentActivityAttributes.ContentState(
            currentStep: 0,
            totalSteps: 1,
            thought: "Starting...",
            phase: "thinking",
            elapsed: "0",
            isComplete: false,
            success: false
        )

        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
        } catch {
            print("Failed to start Live Activity: \(error)")
        }
    }

    private func updateLiveActivity(_ status: AgentStatusResponse) {
        guard let activity = currentActivity else { return }

        let newState = AgentActivityAttributes.ContentState(
            currentStep: status.currentStep,
            totalSteps: max(status.totalSteps, 1),
            thought: status.thought,
            phase: status.phase,
            elapsed: status.elapsed,
            isComplete: false,
            success: false
        )

        Task {
            await activity.update(using: newState)
        }
    }

    private func endLiveActivity(success: Bool) {
        guard let activity = currentActivity else { return }

        let finalState = AgentActivityAttributes.ContentState(
            currentStep: currentState?.currentStep ?? 0,
            totalSteps: currentState?.totalSteps ?? 1,
            thought: success ? "Done!" : "Failed",
            phase: success ? "complete" : "failed",
            elapsed: currentState?.elapsed ?? "0",
            isComplete: true,
            success: success
        )

        Task {
            await activity.end(using: finalState, dismissalPolicy: .after(.now + 8))
            await MainActor.run { self.currentActivity = nil }
        }
    }
}
