import Foundation
import FoundationModels

// MARK: - Personal Assistant (Apple Foundation Models, on-device, free)

@Observable
final class AssistantService {
    static let shared = AssistantService()

    var messages: [ChatMessage] = []
    var isGenerating = false
    var streamingText = ""

    // Model selection: "apple" (free, on-device), "openai", "gemini"
    var chatProvider: String = UserDefaults.standard.string(forKey: "chatProvider") ?? "apple" {
        didSet { UserDefaults.standard.set(chatProvider, forKey: "chatProvider") }
    }

    private var session: LanguageModelSession?

    struct ChatMessage: Codable, Identifiable, Equatable {
        let id: UUID
        let role: String // "user" or "assistant"
        let text: String
        let timestamp: Date
        let provider: String? // "apple", "openai", "gemini"
        let toolsUsed: [String]? // e.g. ["webSearch", "recallMemory"]
        let logs: [String]? // agent-style logs with timestamps

        init(role: String, text: String, provider: String? = nil, toolsUsed: [String]? = nil, logs: [String]? = nil) {
            self.id = UUID()
            self.role = role
            self.text = text
            self.timestamp = Date()
            self.provider = provider
            self.toolsUsed = toolsUsed
            self.logs = logs
        }
    }

    // Track tools used in current response (accessible from Tool structs)
    var currentToolsUsed: [String] = []
    var currentLogs: [String] = []
    private var lastUserMessage: String = ""

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func log(_ message: String) {
        let ts = Self.timestampFormatter.string(from: Date())
        currentLogs.append("[\(ts)] \(message)")
    }

    // MARK: - File Paths

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var memoriesURL: URL { docsDir.appendingPathComponent("memories/user.md") }
    private var historyURL: URL { docsDir.appendingPathComponent("logs/tasks.jsonl") }
    private var chatHistoryURL: URL { docsDir.appendingPathComponent("chat_history.json") }

    // MARK: - Initialization

    func setup() {
        loadChatHistory()
        initSession()
    }

    private func initSession() {
        let instructions = SystemPromptBuilder.build(mode: .chat)

        session = LanguageModelSession(
            tools: [SaveMemoryTool(), RecallMemoryTool(), RecallHistoryTool(), WebSearchTool()],
            instructions: instructions
        )
    }

    // MARK: - Send Message

    private var requestStart: Date = Date()

    func send(_ text: String) {
        let userMessage = ChatMessage(role: "user", text: text)
        messages.append(userMessage)
        lastUserMessage = text
        isGenerating = true
        streamingText = ""
        currentToolsUsed = []
        currentLogs = []
        requestStart = Date()

        let modelLabel = chatProvider == "apple" ? "apple-fm (on-device)" : chatProvider == "openai" ? "gpt-5.4 (openai)" : "gemini-2.5-flash-lite (gemini)"

        log("=== Task: \(text) ===")
        log("Model: \(modelLabel)")
        log("")

        Task {
            do {
                if chatProvider == "apple" {
                    try await sendViaApple(text)
                } else {
                    try await sendViaAPI(text)
                }
            } catch {
                log("[AI] ERROR: \(error.localizedDescription)")
                await finishResponse("Sorry, I couldn't process that: \(error.localizedDescription)")
            }
        }
    }

    private func sendViaApple(_ text: String) async throws {
        if session == nil { initSession() }
        guard let session else { return }

        let aiStart = Date()
        log("[AI] Sending to Apple Foundation Model (on-device)...")

        let stream = session.streamResponse(to: text)
        var accumulated = ""
        for try await partial in stream {
            accumulated = partial.content
            let current = accumulated
            await MainActor.run {
                self.streamingText = current
            }
        }
        let aiTime = String(format: "%.1f", Date().timeIntervalSince(aiStart))
        log("[AI] Responded in \(aiTime)s")
        if !currentToolsUsed.isEmpty {
            log("[Tools] Used: \(currentToolsUsed.joined(separator: ", "))")
        }
        log("[AI] \(String(accumulated.prefix(200)))")
        let totalTime = String(format: "%.1f", Date().timeIntervalSince(requestStart))
        log("")
        log("=== Complete (\(totalTime)s total) ===")
        await finishResponse(accumulated)
    }

    private func sendViaAPI(_ text: String) async throws {
        let apiKey: String
        let url: URL
        let model: String

        if chatProvider == "openai" {
            apiKey = UserDefaults.standard.string(forKey: "openAIKey") ?? ""
            url = URL(string: "https://api.openai.com/v1/chat/completions")!
            model = "gpt-5.4"
        } else {
            apiKey = UserDefaults.standard.string(forKey: "geminiKey") ?? ""
            url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            model = "gemini-2.5-flash-lite"
        }

        guard !apiKey.isEmpty else {
            await finishResponse("No API key configured for \(chatProvider). Go to Settings (gear icon) to add one.")
            return
        }

        let systemPrompt = SystemPromptBuilder.build(mode: .chat)

        // Build messages array from chat history (last 20 messages for context)
        var apiMessages: [[String: Any]] = [["role": "system", "content": systemPrompt]]
        for msg in messages.suffix(20) {
            apiMessages.append(["role": msg.role, "content": msg.text])
        }

        // Tool definitions for API
        let apiTools: [[String: Any]] = [
            ["type": "function", "function": [
                "name": "saveMemory",
                "description": "Save a fact, reminder, or note about the user to persistent memory.",
                "parameters": ["type": "object", "properties": ["fact": ["type": "string", "description": "The fact to save"]], "required": ["fact"]],
            ]],
            ["type": "function", "function": [
                "name": "recallMemory",
                "description": "Read all saved memories and facts about the user.",
                "parameters": ["type": "object", "properties": [String: Any]()],
            ]],
            ["type": "function", "function": [
                "name": "recallHistory",
                "description": "Read the user's task history.",
                "parameters": ["type": "object", "properties": [String: Any]()],
            ]],
            ["type": "function", "function": [
                "name": "webSearch",
                "description": "Search the web for information. Use for weather, news, facts, scores, prices, how-to.",
                "parameters": ["type": "object", "properties": ["query": ["type": "string", "description": "Search query"]], "required": ["query"]],
            ]],
        ]

        // First API call (with tools)
        let aiStart = Date()
        log("[AI] Sending to \(model)...")

        let response = try await callAPI(url: url, apiKey: apiKey, model: model, messages: apiMessages, tools: apiTools)
        let aiTime = String(format: "%.1f", Date().timeIntervalSince(aiStart))
        log("[AI] Responded in \(aiTime)s")

        guard let choices = response["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            await finishResponse("Failed to get response from \(chatProvider).")
            return
        }

        // Check for tool calls
        if let toolCalls = msg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty {
            // Add assistant message with tool calls
            apiMessages.append(msg)

            log("[AI] Decided to call \(toolCalls.count) tool(s)")

            // Execute each tool
            for tc in toolCalls {
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let tcId = tc["id"] as? String else { continue }
                let argsStr = fn["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

                currentToolsUsed.append(name)
                log("[Tool] \(name)")

                let toolStart = Date()
                let result: String
                switch name {
                case "saveMemory":
                    let fact = args["fact"] as? String ?? ""
                    saveMemoryFact(fact)
                    result = "Saved: \(fact)"
                    log("[Tool] saveMemory → Saved: \"\(fact)\"")
                case "recallMemory":
                    let content = loadMemoryFile()
                    result = content.isEmpty ? "No memories saved yet." : content
                    let factCount = content.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
                    log("[Tool] recallMemory → \(factCount) facts loaded")
                case "recallHistory":
                    result = loadHistoryText()
                    log("[Tool] recallHistory → \(String(result.prefix(80)))")
                case "webSearch":
                    let query = args["query"] as? String ?? ""
                    log("[Tool] webSearch → query: \"\(query)\"")
                    result = await executeWebSearch(query)
                    let resultCount = result.components(separatedBy: "\n").filter { $0.first?.isNumber == true }.count
                    let searchTime = String(format: "%.1f", Date().timeIntervalSince(toolStart))
                    log("[Tool] webSearch → \(resultCount) results in \(searchTime)s")
                default:
                    result = "Unknown tool"
                    log("[Tool] Unknown: \(name)")
                }

                apiMessages.append(["role": "tool", "tool_call_id": tcId, "content": result])
            }

            // Second API call with tool results
            let followUpStart = Date()
            log("[AI] Following up with tool results...")
            let followUp = try await callAPI(url: url, apiKey: apiKey, model: model, messages: apiMessages, tools: nil)
            let followUpTime = String(format: "%.1f", Date().timeIntervalSince(followUpStart))
            log("[AI] Follow-up responded in \(followUpTime)s")

            if let choices2 = followUp["choices"] as? [[String: Any]],
               let msg2 = choices2.first?["message"] as? [String: Any],
               let content = msg2["content"] as? String {
                log("[AI] \(String(content.prefix(200)))")
                let totalTime = String(format: "%.1f", Date().timeIntervalSince(requestStart))
                log("")
                log("=== Complete (\(totalTime)s total) ===")
                await finishResponse(content)
            } else {
                await finishResponse("Failed to process tool results.")
            }
        } else if let content = msg["content"] as? String {
            log("[AI] \(String(content.prefix(200)))")
            let totalTime = String(format: "%.1f", Date().timeIntervalSince(requestStart))
            log("")
            log("=== Complete (\(totalTime)s total) ===")
            await finishResponse(content)
        } else {
            await finishResponse("No response.")
        }
    }

    private func callAPI(url: URL, apiKey: String, model: String, messages: [[String: Any]], tools: [[String: Any]]?) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["model": model, "messages": messages]
        if let tools { body["tools"] = tools; body["tool_choice"] = "auto" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func loadHistoryText() -> String {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return "No task history yet." }
        let lines = text.split(separator: "\n")
        let recent = lines.suffix(10).compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let task = json["task"] as? String ?? ""
            let success = json["success"] as? Bool ?? false
            let date = (json["timestamp"] as? String ?? "").split(separator: "T").first ?? ""
            return "[\(date)] \"\(task)\" — \(success ? "completed" : "failed")"
        }
        return recent.isEmpty ? "No task history yet." : "Recent tasks:\n\(recent.joined(separator: "\n"))"
    }

    private func executeWebSearch(_ query: String) async -> String {
        let braveKey = UserDefaults.standard.string(forKey: "braveKey") ?? ""
        guard !braveKey.isEmpty else { return "Web search not configured." }
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "count", value: "5")]
        var req = URLRequest(url: components.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(braveKey, forHTTPHeaderField: "X-Subscription-Token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else { return "No results." }
        return results.prefix(5).enumerated().map { i, r in
            "\(i + 1). \(r["title"] as? String ?? ""): \(r["description"] as? String ?? "")"
        }.joined(separator: "\n")
    }

    @MainActor
    private func finishResponse(_ text: String) {
        let tools = currentToolsUsed.isEmpty ? nil : currentToolsUsed
        let finalLogs = currentLogs.isEmpty ? nil : currentLogs
        let assistantMessage = ChatMessage(role: "assistant", text: text, provider: chatProvider, toolsUsed: tools, logs: finalLogs)
        messages.append(assistantMessage)

        // Log to history so it appears in History tab
        logChatToHistory(question: lastUserMessage, answer: text, tools: currentToolsUsed, logs: currentLogs)
        currentToolsUsed = []
        currentLogs = []
        isGenerating = false
        streamingText = ""
        saveChatHistory()
    }

    // MARK: - Chat History Persistence

    private func loadChatHistory() {
        guard let data = try? Data(contentsOf: chatHistoryURL),
              let saved = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        // Keep last 50 messages
        messages = Array(saved.suffix(50))
    }

    private func saveChatHistory() {
        // Keep last 50 messages
        let toSave = Array(messages.suffix(50))
        guard let data = try? JSONEncoder().encode(toSave) else { return }
        try? data.write(to: chatHistoryURL, options: .atomic)
    }

    func clearChat() {
        messages = []
        saveChatHistory()
        // Reinitialize session to clear context
        initSession()
    }

    func newChat() {
        // Current messages are already logged to history via logChatToHistory
        // Just clear and start fresh
        messages = []
        saveChatHistory()
        initSession()
    }

    // MARK: - Memory Helpers (shared with OnDeviceAgent)

    func loadMemoryFile() -> String {
        guard let data = try? Data(contentsOf: memoriesURL),
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              content != "# User Memory" else { return "" }
        return content
    }

    func saveMemoryFact(_ fact: String) {
        let dir = memoriesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dateStr = Self.dateFormatter.string(from: Date())
        var existing = (try? String(contentsOf: memoriesURL, encoding: .utf8)) ?? "# User Memory\n"
        existing += "- [\(dateStr)] \(fact)\n"
        try? existing.write(to: memoriesURL, atomically: true, encoding: .utf8)
    }

    private func logChatToHistory(question: String, answer: String, tools: [String], logs: [String]) {
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let modelLabel = chatProvider == "apple" ? "apple-fm" : chatProvider == "openai" ? "gpt-5.4" : "gemini-2.5-flash-lite"

        let entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "task": question,
            "summary": String(answer.prefix(100)),
            "steps": 1,
            "time": "0",
            "success": true,
            "mode": "chat",
            "model": modelLabel,
            "provider": chatProvider,
            "agentLogs": logs,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: entry),
           var json = String(data: data, encoding: .utf8) {
            json += "\n"
            let existing = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? ""
            try? (existing + json).write(to: historyURL, atomically: true, encoding: .utf8)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

// MARK: - Tools

struct SaveMemoryTool: Tool {
    let name = "saveMemory"
    let description = "Save a fact, reminder, or note about the user to persistent memory. Use when the user says 'remember this', 'remind me', or shares personal info."

    @Generable
    struct Arguments {
        @Guide(description: "The fact or reminder to save, e.g. 'Homework due Friday' or 'Prefers dark roast coffee'")
        var fact: String
    }

    func call(arguments: Arguments) async throws -> String {
        AssistantService.shared.currentToolsUsed.append("saveMemory")
        AssistantService.shared.log("[Tool] saveMemory → \(arguments.fact)")
        AssistantService.shared.saveMemoryFact(arguments.fact)
        return "Saved to memory: \(arguments.fact)"
    }
}

struct RecallMemoryTool: Tool {
    let name = "recallMemory"
    let description = "Read all saved memories, reminders, and facts about the user. Use when asked 'what do you remember?' or 'did I tell you about...?'"

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        AssistantService.shared.currentToolsUsed.append("recallMemory")
        let content = AssistantService.shared.loadMemoryFile()
        let result = content.isEmpty ? "No memories saved yet." : content
        AssistantService.shared.log("[Tool] recallMemory → \(String(result.prefix(100)))")
        return result
    }
}

struct RecallHistoryTool: Tool {
    let name = "recallHistory"
    let description = "Read the user's task history — what the agent has done before. Use when asked about past tasks or actions."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        AssistantService.shared.currentToolsUsed.append("recallHistory")
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docsDir.appendingPathComponent("logs/tasks.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            let result = "No task history yet."
            AssistantService.shared.log("[Tool] recallHistory → \(result)")
            return result
        }
        let lines = text.split(separator: "\n")
        let recent = lines.suffix(10).compactMap { line -> String? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let task = json["task"] as? String ?? ""
            let success = json["success"] as? Bool ?? false
            let steps = json["steps"] as? Int ?? 0
            let time = json["time"] as? String ?? "0"
            let date = (json["timestamp"] as? String ?? "").split(separator: "T").first ?? ""
            return "[\(date)] \"\(task)\" — \(success ? "completed" : "failed") in \(steps) steps (\(time)s)"
        }
        let result = recent.isEmpty ? "No task history yet." : "Recent tasks:\n\(recent.joined(separator: "\n"))"
        AssistantService.shared.log("[Tool] recallHistory → \(String(result.prefix(100)))")
        return result
    }
}

struct WebSearchTool: Tool {
    let name = "webSearch"
    let description = "Search the web for information. Use for facts, news, weather, how-to questions, or anything the user asks that you don't know."

    @Generable
    struct Arguments {
        @Guide(description: "Search query")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        AssistantService.shared.currentToolsUsed.append("webSearch")
        AssistantService.shared.log("[Tool] webSearch → query: \"\(arguments.query)\"")

        let braveKey = UserDefaults.standard.string(forKey: "braveKey") ?? ""
        guard !braveKey.isEmpty else { return "Web search not configured. Add a Brave API key in Settings." }

        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: arguments.query),
            URLQueryItem(name: "count", value: "5"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(braveKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return "No results found."
        }
        let formatted = results.prefix(5).enumerated().map { i, r in
            let title = r["title"] as? String ?? ""
            let desc = r["description"] as? String ?? ""
            return "\(i + 1). \(title): \(desc)"
        }.joined(separator: "\n")
        let result = "Search results for \"\(arguments.query)\":\n\(formatted)"
        AssistantService.shared.log("[Tool] webSearch → \(results.count) results")
        return result
    }
}
