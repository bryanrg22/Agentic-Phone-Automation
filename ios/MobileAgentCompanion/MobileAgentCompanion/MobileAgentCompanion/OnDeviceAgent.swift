import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - On-Device Agent
// Ports agent.mjs to Swift. Runs the observe-decide-act loop entirely on-device,
// talking to the XCTest runner at localhost and LLM APIs over the network.

@Observable
final class OnDeviceAgent {
    static let shared = OnDeviceAgent()

    // MARK: - Configuration (persisted)
    var xcTestPort: Int {
        get { UserDefaults.standard.integer(forKey: "xcTestPort").nonZero ?? 22087 }
        set { UserDefaults.standard.set(newValue, forKey: "xcTestPort") }
    }
    var provider: String {
        get { UserDefaults.standard.string(forKey: "llmProvider") ?? "openai" }
        set { UserDefaults.standard.set(newValue, forKey: "llmProvider") }
    }
    var modelName: String {
        get { UserDefaults.standard.string(forKey: "llmModel") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "llmModel") }
    }
    var openAIKey: String {
        get { UserDefaults.standard.string(forKey: "openAIKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "openAIKey") }
    }
    var geminiKey: String {
        get { UserDefaults.standard.string(forKey: "geminiKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "geminiKey") }
    }
    var braveKey: String {
        get { UserDefaults.standard.string(forKey: "braveKey") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "braveKey") }
    }
    var maxSteps: Int {
        get { UserDefaults.standard.integer(forKey: "maxSteps").nonZero ?? 25 }
        set { UserDefaults.standard.set(newValue, forKey: "maxSteps") }
    }

    // MARK: - Runtime state
    var isRunning = false
    var currentStatus: AgentStatusResponse?
    var logs: [String] = []

    // HITL
    var pendingQuestion: String?
    var pendingOptions: [String] = []
    private var userResponseContinuation: CheckedContinuation<String, Never>?

    private var runningTask: Task<Void, Never>?
    private var cancelled = false

    // Screen dimensions (set from /deviceInfo)
    private var screenWidth: CGFloat = 393
    private var screenHeight: CGFloat = 852

    // Known apps
    private let knownBundleIds: [String: String] = [
        "Safari": "com.apple.mobilesafari", "Maps": "com.apple.Maps",
        "Messages": "com.apple.MobileSMS", "Calendar": "com.apple.mobilecal",
        "Photos": "com.apple.mobileslideshow", "Camera": "com.apple.camera",
        "Settings": "com.apple.Preferences", "Notes": "com.apple.mobilenotes",
        "Reminders": "com.apple.reminders", "Contacts": "com.apple.MobileAddressBook",
        "Phone": "com.apple.mobilephone", "Mail": "com.apple.mobilemail",
        "Weather": "com.apple.weather", "Clock": "com.apple.mobiletimer",
        "Files": "com.apple.DocumentsApp", "News": "com.apple.news",
        "Health": "com.apple.Health", "Wallet": "com.apple.Passbook",
        "Shortcuts": "com.apple.shortcuts", "Music": "com.apple.Music",
        "Podcasts": "com.apple.podcasts", "App Store": "com.apple.AppStore",
        "Calculator": "com.apple.calculator", "Voice Memos": "com.apple.VoiceMemos",
        "TV": "com.apple.tv", "Passwords": "com.apple.Passwords",
        // Third-party
        "Spotify": "com.spotify.client", "Instagram": "com.burbn.instagram",
        "Snapchat": "com.toyopagroup.picaboo", "TikTok": "com.zhiliaoapp.musically",
        "YouTube": "com.google.ios.youtube", "Gmail": "com.google.Gmail",
        "WhatsApp": "net.whatsapp.WhatsApp", "Telegram": "ph.telegra.Telegraph",
        "Discord": "com.hammerandchisel.discord", "Uber": "com.ubercab.UberClient",
        "Twitter": "com.atebits.Tweetie2", "Reddit": "com.reddit.Reddit",
        "Netflix": "com.netflix.Netflix", "Slack": "com.tinyspeck.chatlyio",
        "ChatGPT": "com.openai.chat", "LinkedIn": "com.linkedin.LinkedIn",
        "GroupMe": "com.groupme.iphone",
    ]

    private var currentAppId: String?
    private var pendingMemories: [String] = []

    // Procedural memory
    private var stepTraces: [StepTrace] = []
    private var matchedProcedure: Procedure?

    // MARK: - File paths

    private var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var memoriesURL: URL { docsDir.appendingPathComponent("memories/user.md") }
    private var historyURL: URL { docsDir.appendingPathComponent("logs/tasks.jsonl") }

    private var resolvedModel: String {
        if !modelName.isEmpty { return modelName }
        return provider == "openai" ? "gpt-5.4" : "gemini-2.5-flash-lite"
    }

    // MARK: - Public API

    /// Seed the on-device memory file from a bundled copy (first launch)
    func seedMemoryIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: memoriesURL.path) else { return }
        // Create directories
        try? fm.createDirectory(at: memoriesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Copy bundled seed file if available
        if let bundled = Bundle.main.url(forResource: "user", withExtension: "md") {
            try? fm.copyItem(at: bundled, to: memoriesURL)
            print("[Memory] Seeded from bundle")
        } else {
            // Create empty memory file
            try? "# User Memory\n".write(to: memoriesURL, atomically: true, encoding: .utf8)
            print("[Memory] Created empty memory file")
        }
    }

    /// Check if the XCTest runner is alive
    func checkRunner() async -> Bool {
        guard let url = URL(string: "http://localhost:\(xcTestPort)/deviceInfo") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = "GET"
        return (try? await URLSession.shared.data(for: req)) != nil
    }

    #if !os(watchOS) && !targetEnvironment(appExtension)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// Start a task
    func run(task: String) {
        guard !isRunning else { return }
        cancelled = false
        isRunning = true
        logs = []
        pendingMemories = []
        stepTraces = []
        matchedProcedure = nil
        currentAppId = nil

        // Keep app alive in background while controlling other apps
        #if !os(watchOS) && !targetEnvironment(appExtension)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "OnDeviceAgent") { [weak self] in
            self?.endBackgroundTask()
        }
        #endif

        let agent = self
        runningTask = Task {
            await agent.agentLoop(task: task)
            await MainActor.run {
                agent.isRunning = false
                agent.endBackgroundTask()
            }
        }
    }

    /// Stop the running task
    func stop() {
        cancelled = true
        runningTask?.cancel()
        runningTask = nil
        isRunning = false
        endBackgroundTask()
        publishStatus(phase: "failed", thought: "Stopped by user", step: currentStatus?.currentStep ?? 0, isComplete: true, success: false)
    }

    private func endBackgroundTask() {
        #if !os(watchOS) && !targetEnvironment(appExtension)
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        #endif
    }

    /// Respond to a HITL question
    func respond(choice: String) {
        userResponseContinuation?.resume(returning: choice)
        userResponseContinuation = nil
        pendingQuestion = nil
        pendingOptions = []
    }

    // MARK: - XCTest HTTP Client

    private func xctest(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: "http://localhost:\(xcTestPort)\(path)") else {
            throw AgentError.badURL(path)
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw AgentError.xctestFailed(path, http.statusCode, String(msg.prefix(150)))
        }
        return data
    }

    private func screenshot() async throws -> String {
        let data = try await xctest("GET", "/screenshot")
        return data.base64EncodedString()
    }

    private func viewHierarchy() async throws -> String {
        let appIds = currentAppId.map { [$0] } ?? ["com.apple.springboard"]
        let data = try await xctest("POST", "/viewHierarchy", body: [
            "appIds": appIds,
            "excludeKeyboardElements": false,
        ])
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func touchPoint(_ x: CGFloat, _ y: CGFloat, duration: Double = 0.1) async throws {
        _ = try await xctest("POST", "/touch", body: ["x": x, "y": y, "duration": duration])
    }

    private func inputText(_ text: String) async throws {
        let appIds = currentAppId.map { [$0] } ?? ["com.apple.springboard"]
        _ = try await xctest("POST", "/inputText", body: ["text": text, "appIds": appIds])
    }

    private func pressKey(_ key: String) async throws {
        _ = try await xctest("POST", "/pressKey", body: ["key": key])
    }

    private func swipeGesture(startX: CGFloat, startY: CGFloat, endX: CGFloat, endY: CGFloat, duration: Double = 0.3) async throws {
        _ = try await xctest("POST", "/swipe", body: [
            "startX": startX, "startY": startY,
            "endX": endX, "endY": endY,
            "duration": duration,
        ])
    }

    private func launchApp(_ bundleId: String) async throws {
        _ = try await xctest("POST", "/launchApp", body: ["bundleId": bundleId])
    }

    private func eraseText(_ chars: Int) async throws {
        let appIds = currentAppId.map { [$0] } ?? ["com.apple.springboard"]
        _ = try await xctest("POST", "/eraseText", body: ["charactersToErase": chars, "appIds": appIds])
    }

    private func deviceInfo() async throws -> (width: CGFloat, height: CGFloat) {
        let data = try await xctest("GET", "/deviceInfo")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let w = (json["widthPoints"] as? NSNumber)?.doubleValue ?? 393
        let h = (json["heightPoints"] as? NSNumber)?.doubleValue ?? 852
        return (CGFloat(w), CGFloat(h))
    }

    // MARK: - LLM Client

    private var llmURL: URL {
        if provider == "openai" {
            return URL(string: "https://api.openai.com/v1/chat/completions")!
        } else {
            return URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
        }
    }

    private var apiKey: String {
        provider == "openai" ? openAIKey : geminiKey
    }

    private func callLLM(messages: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        var req = URLRequest(url: llmURL, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": resolvedModel,
            "messages": messages,
            "tools": tools,
            "tool_choice": "auto",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let err = String(data: data, encoding: .utf8) ?? "Unknown"
            throw AgentError.llmFailed(http.statusCode, String(err.prefix(200)))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentError.llmFailed(0, "Invalid JSON")
        }
        return json
    }

    // MARK: - Tool Definitions

    private func toolDefinitions() -> [[String: Any]] {
        let appNames = knownBundleIds.keys.sorted().joined(separator: ", ")
        let defs: [[String: Any?]] = [
            toolDef("openApp", "Open an app by name. Available: \(appNames)", [
                "appName": ["type": "string", "description": "App name"],
            ], required: ["appName"]),
            toolDef("takeScreenshot", "Capture the current screen. Screenshots are auto-captured after action tools, so only use for initial observation or final verification.", [:]),
            toolDef("getUIElements", "Get all UI elements on screen with text, IDs, and positions. More accurate than guessing coordinates from screenshots.", [:]),
            toolDef("tap", "Tap at screen coordinates. MUST be percentages 0-100, NOT pixels.", [
                "x": ["type": "number", "description": "X percentage 0-100"],
                "y": ["type": "number", "description": "Y percentage 0-100"],
                "description": ["type": "string"],
            ], required: ["x", "y"]),
            toolDef("tapText", "Tap on visible text on screen. Uses view hierarchy lookup.", [
                "text": ["type": "string"],
            ], required: ["text"]),
            toolDef("inputText", "Type text into focused field.", [
                "text": ["type": "string"],
            ], required: ["text"]),
            toolDef("pressKey", "Press a key (enter, delete, tab, etc).", [
                "key": ["type": "string"],
            ], required: ["key"]),
            toolDef("scroll", "Scroll down.", [:]),
            toolDef("swipe", "Swipe gesture. Coordinates as percentages.", [
                "startX": ["type": "number"], "startY": ["type": "number"],
                "endX": ["type": "number"], "endY": ["type": "number"],
            ], required: ["startX", "startY", "endX", "endY"]),
            toolDef("hideKeyboard", "Dismiss the keyboard.", [:]),
            toolDef("typeAndSubmit", "Tap a text field, type text, and press enter/send in one step. This tool HANDLES SENDING — do NOT tap send after.", [
                "elementText": ["type": "string", "description": "Text of the field to tap"],
                "text": ["type": "string", "description": "Text to type"],
                "submitKey": ["type": "string", "description": "Key after typing (default: enter). Use 'send' for Messages."],
            ], required: ["elementText", "text"]),
            toolDef("saveMemory", "Save a fact about the user to persistent memory.", [
                "fact": ["type": "string", "description": "The fact to remember"],
            ], required: ["fact"]),
            toolDef("recallMemory", "Read all saved memory.", [:]),
            toolDef("recallHistory", "Read past task history.", [:]),
            toolDef("webSearch", "Search the web for information. Use for unfamiliar apps, facts, or context.", [
                "query": ["type": "string", "description": "Search query"],
            ], required: ["query"]),
            toolDef("askUser", "Ask the user a question when you need confirmation or clarification.", [
                "question": ["type": "string", "description": "The question"],
                "options": ["type": "array", "items": ["type": "string"], "description": "2-4 options"],
            ], required: ["question", "options"]),
            toolDef("taskComplete", "Task is done.", [
                "summary": ["type": "string"],
            ], required: ["summary"]),
            toolDef("taskFailed", "Task cannot be completed.", [
                "reason": ["type": "string"],
            ], required: ["reason"]),
        ]
        return defs.map { tool in
            ["type": "function", "function": tool.compactMapValues { $0 }]
        }
    }

    private func toolDef(_ name: String, _ description: String, _ props: [String: Any], required: [String] = []) -> [String: Any?] {
        var params: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { params["required"] = required }
        return ["name": name, "description": description, "parameters": params]
    }

    // MARK: - System Prompt

    private func systemPrompt() -> String {
        let appListStr = knownBundleIds.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return SystemPromptBuilder.build(mode: .automation, appList: appListStr)
    }

    // MARK: - Tool Executor

    private func executeTool(name: String, args: [String: Any]) async throws -> ToolResult {
        switch name {

        // --- APP LAUNCH ---
        case "openApp":
            let appName = args["appName"] as? String ?? ""
            guard let bid = knownBundleIds[appName] else {
                return .text("App \"\(appName)\" not found. Available: \(knownBundleIds.keys.sorted().joined(separator: ", "))")
            }
            try await launchApp(bid)
            currentAppId = bid
            return .text("Opened \(appName)")

        // --- SCREENSHOT ---
        case "takeScreenshot":
            return .screenshot

        // --- UI ELEMENTS ---
        case "getUIElements":
            let text = try await viewHierarchy()
            let elems = parseHierarchyElements(text)
            let lines = elems.map { e in
                if let x = e.pctX, let y = e.pctY {
                    return "- \"\(e.label)\" at (\(x)%, \(y)%)"
                }
                return "- \"\(e.label)\""
            }
            return .text("Tappable elements on screen:\n\(lines.joined(separator: "\n"))\n\nUse tap(x, y) with the coordinates above.")

        // --- TAP ---
        case "tap":
            let x = (args["x"] as? NSNumber)?.doubleValue ?? 50
            let y = (args["y"] as? NSNumber)?.doubleValue ?? 50
            if x > 100 || y > 100 {
                return .text("ERROR: Coordinates must be percentages 0-100, not pixels. You sent x=\(x), y=\(y).")
            }
            let px = (x / 100) * Double(screenWidth)
            let py = (y / 100) * Double(screenHeight)
            try await touchPoint(CGFloat(px), CGFloat(py))
            let desc = args["description"] as? String
            return .text("Tapped (\(Int(x))%, \(Int(y))%)\(desc.map { " - \($0)" } ?? "")")

        // --- TAP TEXT ---
        case "tapText":
            let target = args["text"] as? String ?? ""
            let hText = try await viewHierarchy()
            if let el = findElementInHierarchy(hText, label: target) {
                let cx = el.frame.x + el.frame.width / 2
                let cy = el.frame.y + el.frame.height / 2
                try await touchPoint(CGFloat(cx), CGFloat(cy))
                return .text("Tapped \"\(target)\" at pixel (\(Int(cx)), \(Int(cy)))")
            }
            return .text("ERROR: Element \"\(target)\" not found in view hierarchy. Use getUIElements to see available elements, or use tap with coordinates instead.")

        // --- INPUT TEXT ---
        case "inputText":
            let text = args["text"] as? String ?? ""
            try await inputText(text)
            return .text("Typed \"\(text)\"")

        // --- PRESS KEY ---
        case "pressKey":
            let key = args["key"] as? String ?? "enter"
            try await pressKey(key)
            return .text("Pressed \(key)")

        // --- SCROLL ---
        case "scroll":
            let midX = screenWidth / 2
            try await swipeGesture(
                startX: midX, startY: screenHeight * 0.7,
                endX: midX, endY: screenHeight * 0.3
            )
            return .text("Scrolled down")

        // --- SWIPE ---
        case "swipe":
            let sx = ((args["startX"] as? NSNumber)?.doubleValue ?? 50) / 100 * Double(screenWidth)
            let sy = ((args["startY"] as? NSNumber)?.doubleValue ?? 50) / 100 * Double(screenHeight)
            let ex = ((args["endX"] as? NSNumber)?.doubleValue ?? 50) / 100 * Double(screenWidth)
            let ey = ((args["endY"] as? NSNumber)?.doubleValue ?? 50) / 100 * Double(screenHeight)
            try await swipeGesture(startX: CGFloat(sx), startY: CGFloat(sy), endX: CGFloat(ex), endY: CGFloat(ey))
            return .text("Swiped")

        // --- HIDE KEYBOARD ---
        case "hideKeyboard":
            try await touchPoint(screenWidth / 2, 50)
            return .text("Keyboard hidden")

        // --- TYPE AND SUBMIT ---
        case "typeAndSubmit":
            let elementText = args["elementText"] as? String ?? ""
            let text = args["text"] as? String ?? ""
            let submitKey = args["submitKey"] as? String ?? "enter"

            // Step 1: Tap the field
            _ = try? await executeTool(name: "tapText", args: ["text": elementText])
            try await Task.sleep(for: .milliseconds(500))

            // Step 2: Type
            try await inputText(text)
            try await Task.sleep(for: .milliseconds(300))

            // Step 3: Submit
            if submitKey == "send" {
                var sendTapped = false
                let hText = try await viewHierarchy()
                if let sendEl = findSendButton(hText) {
                    let cx = sendEl.frame.x + sendEl.frame.width / 2
                    let cy = sendEl.frame.y + sendEl.frame.height / 2
                    try await touchPoint(CGFloat(cx), CGFloat(cy))
                    sendTapped = true
                    try await Task.sleep(for: .milliseconds(500))
                }
                if !sendTapped {
                    try await pressKey("enter")
                }
                return .text("Message sent: \"\(text)\" — the send button was tapped automatically. Do NOT tap send again. Take a screenshot to verify.")
            } else {
                try await pressKey(submitKey)
                return .text("Typed \"\(text)\" into \"\(elementText)\" and submitted via \(submitKey)")
            }

        // --- MEMORY ---
        case "saveMemory":
            let fact = args["fact"] as? String ?? ""
            pendingMemories.append(fact)
            return .text("Will remember: \"\(fact)\"")

        case "recallMemory":
            let content = loadMemoryFile()
            return .text(content.isEmpty ? "(no memories saved yet)" : content)

        case "recallHistory":
            let entries = loadHistoryEntries()
            if entries.isEmpty { return .text("(no task history yet)") }
            let recent = entries.suffix(10).map { e in
                let date = e.timestamp.split(separator: "T").first ?? ""
                return "[\(date)] \"\(e.task)\" — \(e.success ? "completed" : "failed") in \(e.steps) steps (\(e.time)s)"
            }
            return .text("Recent task history:\n\(recent.joined(separator: "\n"))")

        // --- WEB SEARCH ---
        case "webSearch":
            let query = args["query"] as? String ?? ""
            guard !braveKey.isEmpty else { return .text("ERROR: Brave API key not configured.") }
            return try await braveSearch(query)

        // --- ASK USER ---
        case "askUser":
            let question = args["question"] as? String ?? ""
            let options = args["options"] as? [String] ?? []
            log("[askUser] \"\(question)\" — options: \(options.joined(separator: ", "))")
            let choice = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                self.userResponseContinuation = cont
                Task { @MainActor in
                    self.pendingQuestion = question
                    self.pendingOptions = options
                    // Update status so Dynamic Island shows the question
                    self.publishStatus(
                        phase: "waiting",
                        thought: question,
                        step: self.currentStatus?.currentStep ?? 0,
                        waitingForInput: true,
                        inputQuestion: question,
                        inputOptions: options
                    )
                }
            }
            log("[askUser] User responded: \"\(choice)\"")
            return .text("User chose: \"\(choice)\"")

        // --- COMPLETION ---
        case "taskComplete":
            return .done(args["summary"] as? String ?? "Done")

        case "taskFailed":
            return .failed(args["reason"] as? String ?? "Unknown error")

        default:
            return .text("Unknown tool: \(name)")
        }
    }

    // MARK: - Agent Loop

    private func agentLoop(task: String) async {
        let totalStart = Date()
        log("=== Task: \(task) ===")
        log("Model: \(resolvedModel) (\(provider))")

        // Get device info
        do {
            let info = try await deviceInfo()
            screenWidth = info.width
            screenHeight = info.height
            log("Screen: \(Int(screenWidth))x\(Int(screenHeight))")
        } catch {
            log("WARNING: Could not get device info, using defaults")
        }

        publishStatus(phase: "thinking", thought: "Starting...", step: 0, taskName: task)

        // Check procedural memory for a matching procedure
        ProcedureMemory.shared.loadIfNeeded()
        var procedureContext = ""
        if let matchPrompt = ProcedureMemory.shared.buildMatchingPrompt(task: task) {
            log("[Procedures] Checking \(ProcedureMemory.shared.count) procedures for match...")
            do {
                let matchMessages: [[String: Any]] = [
                    ["role": "user", "content": matchPrompt],
                ]
                let matchResult = try await callLLM(messages: matchMessages, tools: [])
                if let choices = matchResult["choices"] as? [[String: Any]],
                   let msg = choices.first?["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    if let matched = ProcedureMemory.shared.parseMatch(response: content) {
                        matchedProcedure = matched
                        procedureContext = ProcedureMemory.shared.promptInjection(for: matched)
                        log("[Procedures] Matched: \"\(matched.pattern)\" (reliability: \(Int(matched.reliability * 100))%)")
                    } else {
                        log("[Procedures] No match found")
                    }
                }
            } catch {
                log("[Procedures] Match check failed: \(error.localizedDescription)")
            }
        } else {
            log("[Procedures] No procedures stored yet")
        }

        // Build initial messages
        var systemPromptText = systemPrompt()
        if !procedureContext.isEmpty {
            systemPromptText += "\n\n" + procedureContext
        }
        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPromptText],
            ["role": "user", "content": task],
        ]
        let tools = toolDefinitions()

        var recentActions: [String] = []
        var rollingSummary: [String] = []
        var prevAutoUICount = -1
        var unchangedScreenCount = 0

        for step in 1...maxSteps {
            guard !cancelled, !Task.isCancelled else {
                log("Cancelled at step \(step)")
                break
            }

            let elapsed = String(format: "%.1f", Date().timeIntervalSince(totalStart))
            log("\n--- Step \(step)/\(maxSteps) (\(elapsed)s) ---")
            publishStatus(phase: "thinking", thought: "Thinking...", step: step, taskName: task, elapsed: elapsed)

            // Stuck detection
            if recentActions.count >= 3 {
                let last3 = Array(recentActions.suffix(3))
                var stuck = last3.allSatisfy { $0 == last3[0] }
                if !stuck {
                    // Semantic: same tool with nearby coordinates
                    stuck = checkSemanticStuck(last3)
                }
                if stuck {
                    messages.append(["role": "user", "content": "WARNING: You have repeated similar actions 3 times with no progress. Try: 1) getUIElements, 2) tap with exact coordinates, 3) a different approach."])
                }
            }

            // Strip old screenshots (single-image mode)
            if rollingSummary.count > 0 {
                // Remove old context message
                messages.removeAll { m in
                    (m["role"] as? String) == "user"
                        && (m["content"] as? String)?.hasPrefix("[Context]") == true
                }
                let ctx = "Action history:\n\(rollingSummary.joined(separator: "\n"))"
                messages.insert(["role": "user", "content": "[Context] \(ctx)"], at: 2)
            }

            // Call LLM
            let aiStart = Date()
            publishStatus(phase: "thinking", thought: "Asking \(resolvedModel)...", step: step, taskName: task, elapsed: elapsed)

            let data: [String: Any]
            do {
                data = try await callLLM(messages: messages, tools: tools)
            } catch {
                log("[AI] ERROR: \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(2))
                continue
            }

            guard let choices = data["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any] else {
                log("[AI] No response")
                continue
            }

            let aiTime = String(format: "%.1f", Date().timeIntervalSince(aiStart))
            log("[AI] Responded in \(aiTime)s")

            if let content = msg["content"] as? String, !content.isEmpty {
                log("[AI] \(String(content.prefix(200)))")
            }

            // Process tool calls
            guard let toolCalls = msg["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
                messages.append(msg)
                continue
            }

            messages.append(msg)

            var needsScreenshot = false
            var needsSettleDelay = false
            var isDone = false
            var isFailed = false
            var doneMsg = ""
            var stepToolTraces: [ToolTrace] = []

            for tc in toolCalls {
                guard let fn = tc["function"] as? [String: Any],
                      let toolName = fn["name"] as? String,
                      let tcId = tc["id"] as? String else { continue }

                let argsStr = fn["arguments"] as? String ?? "{}"
                let toolArgs = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]

                let actionKey = "\(toolName)(\(argsStr))"
                log("[Tool] \(toolName)")
                recentActions.append(actionKey)
                if recentActions.count > 10 { recentActions.removeFirst() }

                publishStatus(phase: "acting", thought: toolName, step: step, taskName: task, elapsed: elapsed, toolName: toolName)

                let toolStart = Date()
                let result: ToolResult
                do {
                    result = try await executeTool(name: toolName, args: toolArgs)
                } catch {
                    result = .text("Error: \(error.localizedDescription)")
                    log("[Tool] ERROR: \(error.localizedDescription)")
                }
                let toolTime = Date().timeIntervalSince(toolStart)

                // Build structured trace for procedural memory
                let traceArgs = toolArgs.mapValues { "\($0)" }
                var traceResult = ""
                var traceTarget: String? = nil

                switch result {
                case .screenshot:
                    needsScreenshot = true
                    traceResult = "screenshot"
                    messages.append(["role": "tool", "tool_call_id": tcId, "content": "Screenshot taken"])

                case .done(let summary):
                    isDone = true
                    doneMsg = summary
                    traceResult = "done: \(String(summary.prefix(100)))"
                    messages.append(["role": "tool", "tool_call_id": tcId, "content": summary])

                case .failed(let reason):
                    isFailed = true
                    doneMsg = reason
                    traceResult = "failed: \(String(reason.prefix(100)))"
                    messages.append(["role": "tool", "tool_call_id": tcId, "content": reason])

                case .text(let text):
                    traceResult = String(text.prefix(100))
                    // Extract target for tap-like tools
                    if toolName == "tapText" { traceTarget = toolArgs["text"] as? String }
                    if toolName == "openApp" { traceTarget = toolArgs["appName"] as? String }
                    if toolName == "typeAndSubmit" { traceTarget = toolArgs["elementText"] as? String }
                    if let desc = toolArgs["description"] as? String { traceTarget = desc }

                    messages.append(["role": "tool", "tool_call_id": tcId, "content": text])
                    // Auto-capture after action tools
                    let actionTools: Set = ["openApp", "tap", "tapText", "inputText", "pressKey", "scroll", "swipe", "typeAndSubmit", "hideKeyboard"]
                    if actionTools.contains(toolName) && !needsScreenshot {
                        needsScreenshot = true
                        let navActions: Set = ["tap", "tapText", "scroll", "swipe", "typeAndSubmit"]
                        if navActions.contains(toolName) { needsSettleDelay = true }
                    }
                    log("[Tool] \(String(text.prefix(100)))")
                }

                // Skip non-action tools in the trace (screenshots, memory, completion markers)
                let traceableTools: Set = ["openApp", "tap", "tapText", "inputText", "pressKey", "scroll", "swipe", "typeAndSubmit", "hideKeyboard", "webSearch"]
                if traceableTools.contains(toolName) {
                    stepToolTraces.append(ToolTrace(
                        tool: toolName,
                        args: traceArgs,
                        result: traceResult,
                        target: traceTarget,
                        time: toolTime
                    ))
                }
            }

            // Record step trace for procedural memory
            if !stepToolTraces.isEmpty {
                let aiTimeVal = Double(aiTime) ?? 0
                stepTraces.append(StepTrace(step: step, tools: stepToolTraces, aiTime: aiTimeVal))
            }

            // Rolling summary
            let toolSummaries = toolCalls.compactMap { tc -> String? in
                guard let fn = tc["function"] as? [String: Any],
                      let name = fn["name"] as? String else { return nil }
                return name
            }
            rollingSummary.append("Step \(step): \(toolSummaries.joined(separator: ", "))")

            // Done/Failed
            if isDone {
                let totalTime = String(format: "%.1f", Date().timeIntervalSince(totalStart))
                log("\n=== TASK COMPLETED in \(totalTime)s (\(step) steps) ===")
                log(doneMsg)
                publishStatus(phase: "complete", thought: doneMsg, step: step, taskName: task, elapsed: totalTime, isComplete: true, success: true)
                logHistory(task: task, summary: doneMsg, steps: step, time: totalTime, success: true, trace: stepTraces)
                flushMemories()

                // Procedural memory: update existing or extract new
                if let proc = matchedProcedure {
                    ProcedureMemory.shared.recordSuccess(id: proc.id)
                    log("[Procedures] Updated \"\(proc.pattern)\" — success recorded")
                } else if stepTraces.count >= 3 {
                    // Extract a new procedure from this successful run (3+ steps = non-trivial)
                    await extractProcedure(task: task, trace: stepTraces)
                }

                return
            }

            if isFailed {
                let totalTime = String(format: "%.1f", Date().timeIntervalSince(totalStart))
                log("\n=== TASK FAILED in \(totalTime)s ===")
                log(doneMsg)
                publishStatus(phase: "failed", thought: doneMsg, step: step, taskName: task, elapsed: totalTime, isComplete: true, success: false)
                logHistory(task: task, summary: doneMsg, steps: step, time: totalTime, success: false, trace: stepTraces)

                // Record failure if a procedure was used
                if let proc = matchedProcedure {
                    ProcedureMemory.shared.recordFailure(id: proc.id)
                    log("[Procedures] Updated \"\(proc.pattern)\" — failure recorded")
                }

                return
            }

            // Settle delay for iOS animations
            if needsScreenshot && needsSettleDelay {
                try? await Task.sleep(for: .milliseconds(350))
            }

            // Auto-capture screenshot + hierarchy
            if needsScreenshot {
                publishStatus(phase: "observing", thought: "Capturing screen...", step: step, taskName: task)

                // Strip old screenshots (single-image mode)
                for i in 0..<messages.count {
                    if let content = messages[i]["content"] as? [[String: Any]],
                       content.contains(where: { ($0["type"] as? String) == "image_url" }) {
                        let textParts = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                        messages[i] = ["role": messages[i]["role"] as? String ?? "user", "content": "[Previous screenshot] \(textParts.joined(separator: " "))"]
                    }
                }

                do {
                    // Fetch screenshot and hierarchy in parallel
                    async let ssTask = screenshot()
                    async let hierTask: String = {
                        (try? await self.viewHierarchy()) ?? ""
                    }()

                    let b64 = try await ssTask
                    let hierText = await hierTask

                    // Parse hierarchy to build UI elements text
                    let elems = parseHierarchyElements(hierText)
                    var uiText = ""
                    if !elems.isEmpty {
                        let lines = elems.map { e in
                            if let x = e.pctX, let y = e.pctY {
                                return "- \"\(e.label)\" at (\(x)%, \(y)%)"
                            }
                            return "- \"\(e.label)\""
                        }
                        uiText = "\n\nUI elements on screen:\n\(lines.joined(separator: "\n"))\nUse tap(x, y) with coordinates above for precise tapping."
                        log("[Auto-UI] \(elems.count) elements bundled")
                    }

                    // Unchanged screen detection
                    let currentCount = elems.count
                    var unchangedWarning = ""
                    if currentCount > 0 && currentCount == prevAutoUICount {
                        unchangedScreenCount += 1
                        if unchangedScreenCount >= 3 {
                            unchangedWarning = "\n\nWARNING: The screen has NOT changed after 3 actions. STOP tapping and try: 1) Read ALL text, 2) webSearch how this app works, 3) Look for elements you missed."
                            unchangedScreenCount = 0
                        }
                    } else {
                        unchangedScreenCount = 0
                    }
                    prevAutoUICount = currentCount

                    messages.append([
                        "role": "user",
                        "content": [
                            ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]],
                            ["type": "text", "text": "Current screen after action.\(uiText)\(unchangedWarning)"],
                        ] as [[String: Any]],
                    ])
                    log("[Screenshot] OK")
                } catch {
                    log("[Screenshot] Failed: \(error.localizedDescription)")
                    messages.append(["role": "user", "content": "Screenshot failed: \(error.localizedDescription). Use getUIElements instead."])
                }
            }
        }

        // Max steps reached
        let totalTime = String(format: "%.1f", Date().timeIntervalSince(totalStart))
        log("Max steps (\(maxSteps)) reached in \(totalTime)s")
        publishStatus(phase: "failed", thought: "Max steps reached", step: maxSteps, taskName: task, elapsed: totalTime, isComplete: true, success: false)
        logHistory(task: task, summary: "Max steps reached", steps: maxSteps, time: totalTime, success: false, trace: stepTraces)

        // Record failure if a procedure was used
        if let proc = matchedProcedure {
            ProcedureMemory.shared.recordFailure(id: proc.id)
            log("[Procedures] Updated \"\(proc.pattern)\" — failure recorded (max steps)")
        }
    }

    // MARK: - Hierarchy Parsing

    private struct UIElement {
        let label: String
        let pctX: Int?
        let pctY: Int?
        let frame: (x: Double, y: Double, width: Double, height: Double)?
    }

    private struct FrameInfo {
        let x: Double, y: Double, width: Double, height: Double
    }

    private let uiNoise: Set<String> = [
        "scroll bar", "battery", "Cellular", "Wi-Fi bars", "PM", "AM",
        "No signal", "Not charging", "signal strength", "battery power",
        "location services", "Location tracking",
    ]

    private func parseHierarchyElements(_ text: String) -> [UIElement] {
        var elems: [UIElement] = []
        var seen = Set<String>()

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return elems
        }

        func collect(_ node: [String: Any]?) {
            guard let node else { return }
            if let label = node["label"] as? String, !label.isEmpty {
                let trimmed = label.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !uiNoise.contains(where: { trimmed.contains($0) }) && !seen.contains(trimmed) {
                    seen.insert(trimmed)
                    var pctX: Int?, pctY: Int?
                    var frame: (x: Double, y: Double, width: Double, height: Double)?
                    if let f = node["frame"] as? [String: Any] {
                        let fx = (f["X"] as? NSNumber)?.doubleValue ?? 0
                        let fy = (f["Y"] as? NSNumber)?.doubleValue ?? 0
                        let fw = (f["Width"] as? NSNumber)?.doubleValue ?? 0
                        let fh = (f["Height"] as? NSNumber)?.doubleValue ?? 0
                        frame = (fx, fy, fw, fh)
                        pctX = Int(((fx + fw / 2) / Double(screenWidth)) * 100)
                        pctY = Int(((fy + fh / 2) / Double(screenHeight)) * 100)
                    }
                    elems.append(UIElement(label: trimmed, pctX: pctX, pctY: pctY, frame: frame))
                }
            }
            if let children = node["children"] as? [[String: Any]] {
                children.forEach { collect($0) }
            }
        }

        let root = json["axElement"] as? [String: Any] ?? json
        collect(root)
        return elems
    }

    private func findElementInHierarchy(_ text: String, label target: String) -> (frame: (x: Double, y: Double, width: Double, height: Double), label: String)? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func find(_ node: [String: Any]?) -> (frame: (x: Double, y: Double, width: Double, height: Double), label: String)? {
            guard let node else { return nil }
            let nodeLabel = node["label"] as? String ?? ""
            let nodeTitle = node["title"] as? String ?? ""
            let nodeId = node["identifier"] as? String ?? ""
            if (nodeLabel == target || nodeTitle == target || nodeId == target), let f = node["frame"] as? [String: Any] {
                let fx = (f["X"] as? NSNumber)?.doubleValue ?? 0
                let fy = (f["Y"] as? NSNumber)?.doubleValue ?? 0
                let fw = (f["Width"] as? NSNumber)?.doubleValue ?? 0
                let fh = (f["Height"] as? NSNumber)?.doubleValue ?? 0
                return (frame: (fx, fy, fw, fh), label: nodeLabel)
            }
            if let children = node["children"] as? [[String: Any]] {
                for child in children {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }

        let root = json["axElement"] as? [String: Any] ?? json
        return find(root)
    }

    private func findSendButton(_ text: String) -> (frame: (x: Double, y: Double, width: Double, height: Double), label: String)? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        func find(_ node: [String: Any]?) -> (frame: (x: Double, y: Double, width: Double, height: Double), label: String)? {
            guard let node else { return nil }
            let label = (node["label"] as? String ?? "").lowercased()
            let identifier = (node["identifier"] as? String ?? "").lowercased()
            if (label.contains("send") || identifier.contains("send") || label == "arrow.up.circle.fill"),
               let f = node["frame"] as? [String: Any] {
                let fx = (f["X"] as? NSNumber)?.doubleValue ?? 0
                let fy = (f["Y"] as? NSNumber)?.doubleValue ?? 0
                let fw = (f["Width"] as? NSNumber)?.doubleValue ?? 0
                let fh = (f["Height"] as? NSNumber)?.doubleValue ?? 0
                return (frame: (fx, fy, fw, fh), label: label)
            }
            if let children = node["children"] as? [[String: Any]] {
                for child in children {
                    if let found = find(child) { return found }
                }
            }
            return nil
        }

        let root = json["axElement"] as? [String: Any] ?? json
        return find(root)
    }

    // MARK: - Stuck Detection

    private func checkSemanticStuck(_ actions: [String]) -> Bool {
        // Parse actions like "tap({"x":50,"y":50})"
        struct Parsed { let tool: String; let x: Double?; let y: Double?; let text: String? }

        let parsed: [Parsed] = actions.compactMap { a in
            guard let paren = a.firstIndex(of: "(") else { return nil }
            let tool = String(a[a.startIndex..<paren])
            let argsStr = String(a[a.index(after: paren)..<(a.index(before: a.endIndex))])
            guard let data = argsStr.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return Parsed(tool: tool, x: nil, y: nil, text: nil)
            }
            return Parsed(
                tool: tool,
                x: (args["x"] as? NSNumber)?.doubleValue,
                y: (args["y"] as? NSNumber)?.doubleValue,
                text: args["text"] as? String
            )
        }

        guard parsed.count == 3, parsed.allSatisfy({ $0.tool == parsed[0].tool }) else { return false }

        // Same tool with nearby coordinates
        if parsed[0].x != nil, parsed[0].y != nil {
            let xs = parsed.compactMap(\.x)
            let ys = parsed.compactMap(\.y)
            if xs.count == 3 && ys.count == 3 {
                if (xs.max()! - xs.min()!) <= 10 && (ys.max()! - ys.min()!) <= 10 {
                    return true
                }
            }
        }

        // Same tapText target
        if parsed[0].tool == "tapText", parsed.allSatisfy({ $0.text == parsed[0].text }) {
            return true
        }

        return false
    }

    // MARK: - Web Search

    private func braveSearch(_ query: String) async throws -> ToolResult {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: "5"),
        ]
        var req = URLRequest(url: components.url!)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
        req.setValue(braveKey, forHTTPHeaderField: "X-Subscription-Token")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            return .text("ERROR: Brave Search API returned \(http.statusCode)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let web = json["web"] as? [String: Any],
              let results = web["results"] as? [[String: Any]] else {
            return .text("No search results found.")
        }
        let formatted = results.prefix(5).enumerated().map { i, r in
            let title = r["title"] as? String ?? ""
            let url = r["url"] as? String ?? ""
            let desc = r["description"] as? String ?? ""
            return "\(i + 1). \(title)\n   \(url)\n   \(desc)"
        }.joined(separator: "\n\n")

        log("[WebSearch] \"\(query)\" -> \(min(results.count, 5)) results")
        return .text("Web search results for \"\(query)\":\n\n\(formatted)")
    }

    // MARK: - Memory & History

    private func loadMemoryFile() -> String {
        guard let data = try? Data(contentsOf: memoriesURL),
              let content = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              content != "# User Memory" else { return "" }
        return content
    }

    private func flushMemories() {
        guard !pendingMemories.isEmpty else { return }
        let dir = memoriesURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dateStr = Self.dateFormatter.string(from: Date())
        var existing = (try? String(contentsOf: memoriesURL, encoding: .utf8)) ?? "# User Memory\n"
        let newEntries = pendingMemories.map { "- [\(dateStr)] \($0)" }.joined(separator: "\n")
        existing += newEntries + "\n"
        try? existing.write(to: memoriesURL, atomically: true, encoding: .utf8)
        log("[Memory] Saved \(pendingMemories.count) facts")
        pendingMemories = []
    }

    private struct HistoryEntry: Codable {
        let timestamp: String
        let task: String
        let summary: String?
        let reason: String?
        let steps: Int
        let time: String
        let success: Bool
        let mode: String?
        let model: String?
        let provider: String?
        let agentLogs: [String]?
        let trace: [StepTrace]?
    }

    private func loadHistoryEntries() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            try? JSONDecoder().decode(HistoryEntry.self, from: Data(line.utf8))
        }
    }

    private func logHistory(task: String, summary: String, steps: Int, time: String, success: Bool, trace: [StepTrace]? = nil) {
        let dir = historyURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry = HistoryEntry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            task: task, summary: success ? summary : nil, reason: success ? nil : summary,
            steps: steps, time: time, success: success,
            mode: "on-device", model: resolvedModel, provider: provider,
            agentLogs: logs,
            trace: trace
        )
        if let data = try? JSONEncoder().encode(entry), var json = String(data: data, encoding: .utf8) {
            json += "\n"
            let existing = (try? String(contentsOf: historyURL, encoding: .utf8)) ?? ""
            try? (existing + json).write(to: historyURL, atomically: true, encoding: .utf8)
            log("[History] Task logged")
        }
    }

    // MARK: - Procedure Extraction

    private func extractProcedure(task: String, trace: [StepTrace]) async {
        let prompt = ProcedureMemory.shared.buildExtractionPrompt(task: task, trace: trace)
        log("[Procedures] Extracting procedure from \(trace.count)-step trace...")

        do {
            let extractMessages: [[String: Any]] = [
                ["role": "user", "content": prompt],
            ]
            let result = try await callLLM(messages: extractMessages, tools: [])
            if let choices = result["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let content = msg["content"] as? String {
                if ProcedureMemory.shared.parseAndStore(extractionResponse: content, fallbackTask: task) {
                    log("[Procedures] New procedure saved (total: \(ProcedureMemory.shared.count))")
                } else {
                    log("[Procedures] Extraction skipped (duplicate or parse failure)")
                }
            }
        } catch {
            log("[Procedures] Extraction failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Status Publishing

    private func publishStatus(
        phase: String, thought: String, step: Int,
        taskName: String? = nil, elapsed: String? = nil,
        isComplete: Bool = false, success: Bool = false,
        toolName: String? = nil,
        waitingForInput: Bool = false, inputQuestion: String? = nil, inputOptions: [String]? = nil
    ) {
        let name = taskName ?? currentStatus?.taskName ?? ""
        let elapsedStr = elapsed ?? currentStatus?.elapsed ?? "0"
        currentStatus = AgentStatusResponse(
            isActive: !isComplete,
            taskName: name,
            currentStep: step,
            totalSteps: maxSteps,
            thought: thought,
            phase: phase,
            toolName: toolName ?? "",
            elapsed: elapsedStr,
            isComplete: isComplete,
            success: success,
            waitingForInput: waitingForInput,
            inputQuestion: inputQuestion,
            inputOptions: inputOptions
        )
    }

    // MARK: - Logging

    private func log(_ message: String) {
        let timestamp = Self.timeFormatter.string(from: Date())
        let line = "[\(timestamp)] \(message)"
        Task { @MainActor in
            self.logs.append(line)
        }
        print("[OnDeviceAgent] \(message)")
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    enum ToolResult {
        case text(String)
        case screenshot
        case done(String)
        case failed(String)
    }

    enum AgentError: LocalizedError {
        case badURL(String)
        case xctestFailed(String, Int, String)
        case llmFailed(Int, String)

        var errorDescription: String? {
            switch self {
            case .badURL(let path): return "Bad URL: \(path)"
            case .xctestFailed(let path, let code, let msg): return "XCTest \(path) failed (\(code)): \(msg)"
            case .llmFailed(let code, let msg): return "LLM API error \(code): \(msg)"
            }
        }
    }
}

// MARK: - Int helper
private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
