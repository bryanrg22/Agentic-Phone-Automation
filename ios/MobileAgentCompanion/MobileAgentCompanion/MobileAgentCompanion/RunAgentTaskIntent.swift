import AppIntents

/// App Intent that appears in Shortcuts automatically.
/// Users can assign this to the Action Button — no manual shortcut setup needed.
struct RunAgentTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Agent Task"
    static var description = IntentDescription("Give the mobile agent a task to execute on your phone.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Task", description: "What should the agent do?", requestValueDialog: "What would you like me to do?")
    var task: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let agent = OnDeviceAgent.shared

        // Check if runner is alive
        let alive = await agent.checkRunner()
        guard alive else {
            return .result(dialog: "The XCTest runner isn't running. Open the app and check the runner status.")
        }

        guard !agent.isRunning else {
            return .result(dialog: "The agent is already running a task.")
        }

        agent.run(task: task)

        // Notify the app to start Live Activity observer
        NotificationCenter.default.post(name: .agentTaskStartedFromIntent, object: nil)

        return .result(dialog: "Starting: \(task)")
    }
}

// The intent automatically appears in the Shortcuts app.
// Users assign it to their Action Button via Settings → Action Button → Shortcut → "Run Agent Task".

extension Notification.Name {
    static let agentTaskStartedFromIntent = Notification.Name("agentTaskStartedFromIntent")
}
