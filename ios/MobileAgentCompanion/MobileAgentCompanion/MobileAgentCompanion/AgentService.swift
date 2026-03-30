import ActivityKit
import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

@Observable
class AgentService {
    var serverURL: String = "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "agentServerURL") }
    }
    var isPolling: Bool = false
    var currentState: AgentStatusResponse?

    private var pollingTask: Task<Void, Never>?
    private var currentActivity: Activity<AgentActivityAttributes>?
    private var wasActive: Bool = false
    private var isEnding: Bool = false
    #if canImport(UIKit)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

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
        let waitingForInput: Bool?
        let inputQuestion: String?
        let inputOptions: [String]?
    }

    func startPolling() {
        guard !serverURL.isEmpty else { return }
        isPolling = true
        #if canImport(UIKit)
        beginBackgroundTask()
        #endif
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        // Register for pushToStartToken so server can start Live Activities remotely
        registerForPushToStart()

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.beginBackgroundTask()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func registerForPushToStart() {
        Task {
            for await tokenData in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                print("[PushToStart] Got token: \(token.prefix(20))...")

                // Send token to server
                guard let url = URL(string: "\(serverURL)/register-push-token") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try? JSONEncoder().encode(["token": token, "type": "pushToStart"])

                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        print("[PushToStart] Registered with server: \(httpResponse.statusCode)")
                    }
                } catch {
                    print("[PushToStart] Failed to register: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
        #if canImport(UIKit)
        endBackgroundTask()
        #endif
    }

    #if canImport(UIKit)
    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "AgentPolling") { [weak self] in
            self?.endBackgroundTask()
            self?.beginBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
    }
    #endif

    private func poll() async {
        guard let url = URL(string: "\(serverURL)/status") else { return }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let status = try JSONDecoder().decode(AgentStatusResponse.self, from: data)

            print("[Poll] isActive: \(status.isActive) | phase: \(status.phase) | step: \(status.currentStep)")

            await MainActor.run {
                self.currentState = status
                self.handleStatusUpdate(status)
            }
        } catch {
            print("[Poll] Failed: \(error.localizedDescription)")
        }
    }

    private func handleStatusUpdate(_ status: AgentStatusResponse) {
        if status.isActive && !wasActive {
            // Check if a Live Activity was already started by APNs push
            let existingActivities = Activity<AgentActivityAttributes>.activities
            if let existing = existingActivities.first {
                // Reuse the push-started activity
                currentActivity = existing
                print("[LiveActivity] Reusing push-started activity")
            } else {
                // No push-started activity — create one (only works in foreground)
                startLiveActivity(taskName: status.taskName)
            }
            wasActive = true
        }

        if status.isActive {
            updateLiveActivity(status)
        }

        if status.isComplete && wasActive && currentActivity != nil && !isEnding {
            endLiveActivity(success: status.success)
            wasActive = false
        }

        if !status.isActive && !status.isComplete {
            wasActive = false
        }
    }

    private func startLiveActivity(taskName: String) {
        let authInfo = ActivityAuthorizationInfo()
        print("[LiveActivity] areActivitiesEnabled: \(authInfo.areActivitiesEnabled)")
        print("[LiveActivity] frequentPushesEnabled: \(authInfo.frequentPushesEnabled)")

        guard authInfo.areActivitiesEnabled else {
            print("[LiveActivity] Live Activities not enabled — check Settings > mobile-use > Live Activities")
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
            success: false,
            waitingForInput: false,
            inputQuestion: "",
            inputOptions: []
        )

        print("[LiveActivity] Requesting Live Activity for task: \(taskName)")
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil as Date?),
                pushType: .token
            )
            print("[LiveActivity] Activity created: \(currentActivity != nil)")

            // Send the update push token to the server
            if let activity = currentActivity {
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let token = tokenData.map { String(format: "%02x", $0) }.joined()
                        print("[LiveActivity] Push update token: \(token.prefix(20))...")

                        guard let url = URL(string: "\(serverURL)/register-push-token") else { continue }
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try? JSONEncoder().encode(["token": token, "type": "update"])

                        do {
                            let (_, _) = try await URLSession.shared.data(for: request)
                        } catch {
                            print("[LiveActivity] Failed to send update token: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
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
            success: false,
            waitingForInput: status.waitingForInput ?? false,
            inputQuestion: status.inputQuestion ?? "",
            inputOptions: status.inputOptions ?? []
        )

        Task {
            await activity.update(.init(state: newState, staleDate: nil as Date?))
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
            success: success,
            waitingForInput: false,
            inputQuestion: "",
            inputOptions: []
        )

        isEnding = true
        Task {
            // Update first — keeps Dynamic Island alive showing the completed state
            await activity.update(.init(state: finalState, staleDate: nil as Date?))

            // Let the user see the green checkmark for 4 seconds
            try? await Task.sleep(for: .seconds(4))

            // Now actually end — Dynamic Island dismisses, Lock Screen lingers 8s
            await activity.end(.init(state: finalState, staleDate: nil as Date?), dismissalPolicy: ActivityUIDismissalPolicy.after(.now + 8))
            await MainActor.run {
                self.currentActivity = nil
                self.isEnding = false
            }
        }
    }
}
