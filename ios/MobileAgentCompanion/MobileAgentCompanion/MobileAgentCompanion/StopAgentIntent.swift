import AppIntents
import ActivityKit

struct StopAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Agent"
    static var description = IntentDescription("Stops the currently running mobile agent task.")

    init() {}

    func perform() async throws -> some IntentResult {
        // Send stop command to the server
        if let serverURL = UserDefaults.standard.string(forKey: "agentServerURL"),
           let url = URL(string: "\(serverURL)/stop") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try? await URLSession.shared.data(for: request)
        }

        // End all agent Live Activities
        for activity in Activity<AgentActivityAttributes>.activities {
            let finalState = AgentActivityAttributes.ContentState(
                currentStep: 0,
                totalSteps: 1,
                thought: "Stopped by user",
                phase: "failed",
                elapsed: "0",
                isComplete: true,
                success: false,
                waitingForInput: false,
                inputQuestion: "",
                inputOptions: []
            )
            await activity.end(
                .init(state: finalState, staleDate: nil as Date?),
                dismissalPolicy: .immediate
            )
        }

        return .result()
    }
}
