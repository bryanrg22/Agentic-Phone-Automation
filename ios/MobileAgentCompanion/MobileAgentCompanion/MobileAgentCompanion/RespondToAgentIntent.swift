import AppIntents

struct RespondToAgentIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Respond to Agent"
    static var description = IntentDescription("Sends the user's choice back to the agent.")

    @Parameter(title: "Choice")
    var choice: String

    init() {}

    init(choice: String) {
        self.choice = choice
    }

    func perform() async throws -> some IntentResult {
        guard let serverURL = UserDefaults.standard.string(forKey: "agentServerURL"),
              let url = URL(string: "\(serverURL)/respond") else {
            return .result()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["choice": choice])

        try? await URLSession.shared.data(for: request)
        return .result()
    }
}
