import ActivityKit
import Foundation
import Observation
#if !os(watchOS) && !targetEnvironment(appExtension)
import UIKit
#endif

@Observable
class AgentService {
    var serverURL: String = "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "agentServerURL") }
    }
    var isPolling: Bool = false
    var currentState: AgentStatusResponse?
    var taskHistory: [TaskHistoryEntry] = [] {
        didSet { cacheHistory() }
    }

    struct TaskHistoryEntry: Codable, Identifiable, Equatable {
        let timestamp: String
        let task: String
        let summary: String?
        let steps: Int
        let time: String
        let success: Bool
        let mode: String?
        let model: String?
        let provider: String?

        var id: String { timestamp + task }

        var date: Date? {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        }

        static func == (lhs: TaskHistoryEntry, rhs: TaskHistoryEntry) -> Bool {
            lhs.id == rhs.id
        }
    }

    // MARK: - Memories

    var memories: [MemoryEntry] = [] {
        didSet { cacheMemories() }
    }

    struct MemoryEntry: Codable, Identifiable, Equatable {
        let id: Int
        let date: String?
        let fact: String
    }

    func loadCachedMemories() {
        guard let data = UserDefaults.standard.data(forKey: "cachedMemories"),
              let entries = try? JSONDecoder().decode([MemoryEntry].self, from: data) else { return }
        memories = entries
    }

    private func cacheMemories() {
        guard let data = try? JSONEncoder().encode(memories) else { return }
        UserDefaults.standard.set(data, forKey: "cachedMemories")
    }

    func fetchMemories() async {
        guard let url = URL(string: "\(serverURL)/memories") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let remote = try JSONDecoder().decode([MemoryEntry].self, from: data)
            await MainActor.run {
                self.memories = remote
                print("[Memories] Synced \(remote.count) facts")
            }
        } catch {
            print("[Memories] Fetch failed (showing cached): \(error.localizedDescription)")
        }
    }

    func deleteMemory(_ entry: MemoryEntry) async {
        guard let url = URL(string: "\(serverURL)/memories/delete") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["fact": entry.fact])
        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            await MainActor.run {
                self.memories.removeAll { $0.fact == entry.fact }
            }
            print("[Memories] Deleted: \(entry.fact.prefix(40))...")
        } catch {
            print("[Memories] Delete failed: \(error.localizedDescription)")
        }
    }

    func editMemory(_ entry: MemoryEntry, newFact: String) async {
        guard let url = URL(string: "\(serverURL)/memories/edit") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["oldFact": entry.fact, "newFact": newFact])
        do {
            let (_, _) = try await URLSession.shared.data(for: request)
            await fetchMemories() // Refresh from server
            print("[Memories] Edited: \(entry.fact.prefix(30))... → \(newFact.prefix(30))...")
        } catch {
            print("[Memories] Edit failed: \(error.localizedDescription)")
        }
    }

    // MARK: - History Cache

    /// Load cached history from UserDefaults on init
    func loadCachedHistory() {
        guard let data = UserDefaults.standard.data(forKey: "cachedTaskHistory"),
              let entries = try? JSONDecoder().decode([TaskHistoryEntry].self, from: data) else { return }
        taskHistory = entries
    }

    /// Save history to UserDefaults
    private func cacheHistory() {
        guard let data = try? JSONEncoder().encode(taskHistory) else { return }
        UserDefaults.standard.set(data, forKey: "cachedTaskHistory")
    }

    private var pollingTask: Task<Void, Never>?
    private var currentActivity: Activity<AgentActivityAttributes>?
    private var wasActive: Bool = false
    private var isEnding: Bool = false
    private var lastPromptSignature: String?
    #if !os(watchOS) && !targetEnvironment(appExtension)
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
        #if !os(watchOS) && !targetEnvironment(appExtension)
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

        #if !os(watchOS) && !targetEnvironment(appExtension)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.beginBackgroundTask()
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            self?.endBackgroundTask()
        }
        #endif
    }

    private func registerForPushToStart() {
        // 1. Listen for pushToStart token (used by server to START activities)
        Task {
            for await tokenData in Activity<AgentActivityAttributes>.pushToStartTokenUpdates {
                let token = tokenData.map { String(format: "%02x", $0) }.joined()
                print("[PushToStart] Got token: \(token.prefix(20))...")
                await sendTokenToServer(token: token, type: "pushToStart")
            }
        }

        // 2. Listen for ANY new activities (including push-started ones)
        //    This is how Uber/DoorDash get the update token for push-started activities
        Task {
            for await activity in Activity<AgentActivityAttributes>.activityUpdates {
                print("[Activity] New activity detected: \(activity.id)")

                // Reuse push-started activity (only if it's active, not a zombie)
                await MainActor.run {
                    if currentActivity == nil && activity.activityState == .active {
                        currentActivity = activity
                        wasActive = true
                        print("[Activity] Adopted push-started activity")
                    }
                }

                // Get and send the update push token
                Task {
                    for await tokenData in activity.pushTokenUpdates {
                        let token = tokenData.map { String(format: "%02x", $0) }.joined()
                        print("[Activity] Update token: \(token.prefix(20))...")
                        await sendTokenToServer(token: token, type: "update")
                    }
                }
            }
        }
    }

    private func sendTokenToServer(token: String, type: String) async {
        guard let url = URL(string: "\(serverURL)/register-push-token") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["token": token, "type": type])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                print("[Token] Registered \(type) with server: \(httpResponse.statusCode)")
            }
        } catch {
            print("[Token] Failed to register \(type): \(error.localizedDescription)")
        }
    }

    func fetchHistory() async {
        guard let url = URL(string: "\(serverURL)/history") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let remoteEntries = try JSONDecoder().decode([TaskHistoryEntry].self, from: data)
            await MainActor.run {
                // Merge: remote is source of truth, deduplicate by id
                let existingIds = Set(self.taskHistory.map(\.id))
                let newEntries = remoteEntries.filter { !existingIds.contains($0.id) }
                if !newEntries.isEmpty || remoteEntries.count != self.taskHistory.count {
                    self.taskHistory = remoteEntries.reversed() // newest first
                    print("[History] Synced \(remoteEntries.count) tasks (\(newEntries.count) new)")
                }
            }
        } catch {
            print("[History] Fetch failed (showing cached): \(error.localizedDescription)")
            // Cached history stays visible — no action needed
        }
    }

    func stopPolling() {
        isPolling = false
        pollingTask?.cancel()
        pollingTask = nil
        #if !os(watchOS) && !targetEnvironment(appExtension)
        endBackgroundTask()
        #endif
    }

    #if !os(watchOS) && !targetEnvironment(appExtension)
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
            // End any lingering activities from previous tasks
            for stale in Activity<AgentActivityAttributes>.activities where stale.activityState != .active {
                Task { await stale.end(nil, dismissalPolicy: .immediate) }
            }

            // Check if a Live Activity was already started by APNs push (only active ones)
            let existingActivities = Activity<AgentActivityAttributes>.activities.filter { $0.activityState == .active }
            if let existing = existingActivities.first {
                // Reuse the push-started activity
                currentActivity = existing
                wasActive = true
                print("[LiveActivity] Reusing push-started activity (active)")
            } else {
                // No push-started activity — try to create one (only works in foreground)
                startLiveActivity(taskName: status.taskName)
                if currentActivity != nil {
                    wasActive = true
                } else {
                    // Local start failed (visibility) — will retry next poll to check for push-started activity
                    print("[LiveActivity] Waiting for push-to-start activity...")
                }
            }
        }

        // If active but no currentActivity yet, keep checking for push-started activities
        if status.isActive && currentActivity == nil {
            if let pushStarted = Activity<AgentActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
                currentActivity = pushStarted
                wasActive = true
                print("[LiveActivity] Found push-started activity on poll: \(pushStarted.id)")
            }
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
            // Alert only once per unique HITL prompt to avoid repeated island expansions.
            if status.waitingForInput == true, let question = status.inputQuestion, !question.isEmpty {
                let promptSignature = "\(question)|\((status.inputOptions ?? []).joined(separator: "|"))"
                let shouldAlert = promptSignature != lastPromptSignature
                lastPromptSignature = promptSignature
                if shouldAlert {
                    let title = LocalizedStringResource(stringLiteral: "Input Needed")
                    let body = LocalizedStringResource(stringLiteral: question)
                    await activity.update(
                        .init(state: newState, staleDate: nil as Date?),
                        alertConfiguration: AlertConfiguration(
                            title: title,
                            body: body,
                            sound: .default
                        )
                    )
                    return
                }
            } else {
                lastPromptSignature = nil
            }

            if status.waitingForInput == true {
                await activity.update(
                    .init(state: newState, staleDate: nil as Date?)
                )
            } else {
                await activity.update(.init(state: newState, staleDate: nil as Date?))
            }
        }
    }

    private func endLiveActivity(success: Bool) {
        guard let activity = currentActivity else { return }
        let activityId = activity.id

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
            // One-time completion alert to surface final result in Dynamic Island.
            let completionTitle = LocalizedStringResource(stringLiteral: success ? "Task Completed" : "Task Failed")
            let completionBody = LocalizedStringResource(stringLiteral: finalState.thought)
            await activity.update(
                .init(state: finalState, staleDate: nil as Date?),
                alertConfiguration: AlertConfiguration(
                    title: completionTitle,
                    body: completionBody,
                    sound: .default
                )
            )

            // Let the user see the green checkmark for 4 seconds
            try? await Task.sleep(for: .seconds(4))

            // Now actually end — Dynamic Island dismisses, Lock Screen lingers 8s
            await activity.end(.init(state: finalState, staleDate: nil as Date?), dismissalPolicy: ActivityUIDismissalPolicy.after(.now + 8))
            await MainActor.run {
                // Only nil out if this is still the same activity (not overwritten by a new task)
                if self.currentActivity?.id == activityId {
                    self.currentActivity = nil
                }
                self.isEnding = false
            }
        }
    }
}
