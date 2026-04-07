import SwiftUI

struct ContentView: View {
    @State private var service = AgentService()
    @State private var assistant = AssistantService.shared
    @AppStorage("serverAddress") private var serverAddress: String = ""
    @AppStorage("isOnDeviceMode") private var isOnDeviceMode: Bool = false
    @State private var selectedTab = 0
    @State private var editingMemory: AgentService.MemoryEntry?
    @State private var editText = ""
    @State private var taskInput = ""
    @State private var chatInput = ""
    @State private var selectedHistoryEntry: AgentService.TaskHistoryEntry?
    @State private var selectedChatMessage: AssistantService.ChatMessage?
    @State private var runnerAlive = false
    @State private var showSettings = false
    @State private var expandedHistoryGroups: Set<String> = []
    @State private var newMemoryText = ""
    private var agent: OnDeviceAgent { OnDeviceAgent.shared }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mobile Agent")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                        Text("AI Phone Automation")
                            .font(.subheadline)
                            .foregroundStyle(.gray)
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.gray)
                            .padding(8)
                            .background(Color.white.opacity(0.08))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

                // Tab Picker
                Picker("", selection: $selectedTab) {
                    Text("Chat").tag(0)
                    Text("Agent").tag(1)
                    Text("History").tag(2)
                    Text("Memory").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)

                // Content
                if selectedTab == 0 {
                    chatTab
                } else if selectedTab == 1 {
                    statusTab
                } else if selectedTab == 2 {
                    historyTab
                } else {
                    memoryTab
                }
            }
        }
        .onAppear {
            service.loadCachedHistory()
            service.loadCachedMemories()
            agent.seedMemoryIfNeeded()
            assistant.setup()
            // Always load local data (works without Mac)
            Task {
                await service.fetchHistory()
                await service.fetchMemories()
            }
            if !isOnDeviceMode && !serverAddress.isEmpty && !service.isPolling {
                service.serverURL = "http://\(serverAddress):8000"
                service.startPolling()
            }
            // If agent is already running (started from Action Button intent), start Live Activity observer
            if agent.isRunning && !service.isOnDeviceMode {
                isOnDeviceMode = true
                service.isOnDeviceMode = true
                service.startOnDeviceMode()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentTaskStartedFromIntent)) { _ in
            isOnDeviceMode = true
            service.isOnDeviceMode = true
            if !service.isPolling {
                service.startOnDeviceMode()
            }
        }
        .onChange(of: selectedTab) {
            if selectedTab == 2 {
                Task { await service.fetchHistory() }
            } else if selectedTab == 3 {
                Task { await service.fetchMemories() }
            }
        }
        .sheet(item: $editingMemory) { memory in
            editMemorySheet(memory)
        }
        .sheet(item: $selectedHistoryEntry) { entry in
            historyDetailSheet(entry)
        }
        .sheet(item: $selectedChatMessage) { message in
            chatDetailSheet(message)
        }
        .sheet(isPresented: $showSettings) {
            onDeviceSettingsSheet
        }
    }

    // MARK: - Chat Tab

    private var chatTab: some View {
        VStack(spacing: 0) {
            // Model picker
            HStack(spacing: 8) {
                ForEach(["apple", "openai", "gemini"], id: \.self) { provider in
                    Button {
                        assistant.chatProvider = provider
                    } label: {
                        Text(provider == "apple" ? "Apple" : provider == "openai" ? "GPT" : "Gemini")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(assistant.chatProvider == provider ? Color(hex: "4A9EFF").opacity(0.2) : Color.white.opacity(0.04))
                            .foregroundStyle(assistant.chatProvider == provider ? Color(hex: "4A9EFF") : .gray)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                if !assistant.messages.isEmpty {
                    Button {
                        assistant.newChat()
                    } label: {
                        Image(systemName: "plus.bubble")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: "4A9EFF").opacity(0.6))
                    }
                    Button {
                        assistant.clearChat()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if assistant.messages.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "brain.head.profile")
                                    .font(.system(size: 44))
                                    .foregroundStyle(Color(hex: "4A9EFF").opacity(0.4))
                                Text("Personal Assistant")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                                Text("Ask me anything, tell me to remember things, or check what I know about you.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.gray)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                        }

                        ForEach(assistant.messages) { message in
                            chatBubble(message)
                                .id(message.id)
                        }

                        // Streaming indicator
                        if assistant.isGenerating && !assistant.streamingText.isEmpty {
                            HStack {
                                Text(assistant.streamingText)
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(12)
                                    .background(Color.white.opacity(0.06))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .id("streaming")
                        } else if assistant.isGenerating {
                            HStack {
                                ProgressView()
                                    .tint(Color(hex: "4A9EFF"))
                                    .padding(12)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .id("loading")
                        }
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: assistant.messages.count) {
                    if let last = assistant.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: assistant.streamingText) {
                    withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }

            // Input bar
            HStack(spacing: 10) {
                TextField("Ask anything...", text: $chatInput)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    let text = chatInput.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    chatInput = ""
                    assistant.send(text)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            chatInput.trimmingCharacters(in: .whitespaces).isEmpty
                                ? .gray.opacity(0.3)
                                : Color(hex: "4A9EFF")
                        )
                }
                .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || assistant.isGenerating)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black)
        }
    }

    private func chatBubble(_ message: AssistantService.ChatMessage) -> some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }

            VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.role == "user"
                            ? Color(hex: "4A9EFF").opacity(0.3)
                            : Color.white.opacity(0.06)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)

                if message.role == "assistant" {
                    HStack(spacing: 6) {
                        if let provider = message.provider {
                            Text(provider == "apple" ? "Apple" : provider == "openai" ? "GPT-5.4" : "Gemini")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(provider == "apple" ? .gray.opacity(0.5) : Color(hex: "4A9EFF").opacity(0.5))
                        }
                        if let tools = message.toolsUsed, !tools.isEmpty {
                            ForEach(tools, id: \.self) { tool in
                                Text(tool)
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.orange.opacity(0.6))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.08))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.leading, 8)
                }
            }
            .onTapGesture {
                if message.role == "assistant" {
                    selectedChatMessage = message
                }
            }

            if message.role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Status Tab

    private var statusTab: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Mode toggle
                modeToggle

                if isOnDeviceMode {
                    onDeviceCard
                    if let state = agent.currentStatus {
                        if state.isActive {
                            activeAgentCard(state)
                        } else if state.isComplete {
                            completionCard(state)
                        }
                    }
                    if !agent.logs.isEmpty {
                        agentLogsCard
                    }
                } else {
                    connectionCard

                    if service.isPolling {
                        if let state = service.currentState {
                            if state.isActive {
                                activeAgentCard(state)
                            } else if state.isComplete {
                                completionCard(state)
                            } else {
                                idleCard
                            }
                        } else {
                            connectingCard
                        }
                    } else {
                        getStartedCard
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        HStack(spacing: 12) {
            Button {
                isOnDeviceMode = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 12))
                    Text("Mac")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(!isOnDeviceMode ? Color(hex: "4A9EFF").opacity(0.15) : Color.white.opacity(0.04))
                .foregroundStyle(!isOnDeviceMode ? Color(hex: "4A9EFF") : .gray)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Button {
                isOnDeviceMode = true
                Task {
                    runnerAlive = await agent.checkRunner()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "iphone")
                        .font(.system(size: 12))
                    Text("On-Device")
                        .font(.system(size: 13, weight: .medium))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isOnDeviceMode ? Color(hex: "4A9EFF").opacity(0.15) : Color.white.opacity(0.04))
                .foregroundStyle(isOnDeviceMode ? Color(hex: "4A9EFF") : .gray)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Spacer()
        }
    }

    // MARK: - On-Device Card

    private var onDeviceCard: some View {
        VStack(spacing: 14) {
            // Runner status
            HStack {
                Circle()
                    .fill(runnerAlive ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(runnerAlive ? "Runner online (port \(agent.xcTestPort))" : "Runner offline")
                    .font(.system(size: 13))
                    .foregroundStyle(runnerAlive ? .white.opacity(0.7) : .red.opacity(0.8))
                Spacer()
                Button {
                    Task { runnerAlive = await agent.checkRunner() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "4A9EFF"))
                }
            }

            // Task input
            HStack(spacing: 10) {
                TextField("Describe a task...", text: $taskInput)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    guard !taskInput.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let task = taskInput
                    taskInput = ""
                    agent.run(task: task)
                    service.isOnDeviceMode = true
                    service.startOnDeviceMode()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(
                            (runnerAlive && !agent.isRunning)
                                ? Color(hex: "4A9EFF")
                                : Color.gray.opacity(0.3)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!runnerAlive || agent.isRunning)
            }

            if agent.isRunning {
                Button {
                    agent.stop()
                } label: {
                    HStack {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12))
                        Text("Stop Agent")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.15))
                    .foregroundStyle(.red)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }

            if !runnerAlive && !agent.isRunning {
                Text("Connect to Mac once to start the XCTest runner, then switch to on-device mode.")
                    .font(.system(size: 12))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            Task { runnerAlive = await agent.checkRunner() }
        }
    }

    // MARK: - Settings Sheet

    // MARK: - Agent Logs Card

    private var agentLogsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundStyle(Color(hex: "4A9EFF"))
                    .font(.system(size: 13))
                Text("Agent Logs")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.gray)
                Spacer()
                Text("\(agent.logs.count) lines")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray.opacity(0.5))
                Button {
                    agent.logs = []
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.5))
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(agent.logs.suffix(50).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(logColor(line))
                            .lineLimit(3)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func logColor(_ line: String) -> Color {
        if line.contains("ERROR") || line.contains("FAILED") { return .red.opacity(0.9) }
        if line.contains("WARNING") { return .yellow.opacity(0.8) }
        if line.contains("[AI]") { return Color(hex: "4A9EFF").opacity(0.9) }
        if line.contains("[Tool]") { return .orange.opacity(0.8) }
        if line.contains("[Screenshot]") { return .purple.opacity(0.8) }
        if line.contains("COMPLETED") { return .green.opacity(0.9) }
        return .white.opacity(0.5)
    }

    private var onDeviceSettingsSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 20) {
                HStack {
                    Text("On-Device Settings")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Done") { showSettings = false }
                        .foregroundStyle(Color(hex: "4A9EFF"))
                }

                Group {
                    settingField("Provider", text: Binding(
                        get: { agent.provider },
                        set: { agent.provider = $0 }
                    ), placeholder: "openai")

                    settingField("Model", text: Binding(
                        get: { agent.modelName },
                        set: { agent.modelName = $0 }
                    ), placeholder: "gpt-5.4")

                    settingField("OpenAI Key", text: Binding(
                        get: { agent.openAIKey },
                        set: { agent.openAIKey = $0 }
                    ), placeholder: "sk-...", secure: true)

                    settingField("Gemini Key", text: Binding(
                        get: { agent.geminiKey },
                        set: { agent.geminiKey = $0 }
                    ), placeholder: "AI...", secure: true)

                    settingField("Brave Key", text: Binding(
                        get: { agent.braveKey },
                        set: { agent.braveKey = $0 }
                    ), placeholder: "BSA...", secure: true)

                    HStack {
                        Text("Max Steps")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Spacer()
                        TextField("25", value: Binding(
                            get: { agent.maxSteps },
                            set: { agent.maxSteps = $0 }
                        ), format: .number)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    HStack {
                        Text("XCTest Port")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray)
                        Spacer()
                        TextField("22087", value: Binding(
                            get: { agent.xcTestPort },
                            set: { agent.xcTestPort = $0 }
                        ), format: .number)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.large])
    }

    private func settingField(_ label: String, text: Binding<String>, placeholder: String, secure: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(.gray)
            if secure {
                SecureField(placeholder, text: text)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                TextField(placeholder, text: text)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        ScrollView {
            VStack(spacing: 12) {
                if service.taskHistory.isEmpty {
                    emptyHistoryCard
                } else {
                    ForEach(groupedHistory, id: \.key) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(group.key)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.gray)
                                Spacer()
                                if group.entries.count > 2 {
                                    Button {
                                        if expandedHistoryGroups.contains(group.key) {
                                            expandedHistoryGroups.remove(group.key)
                                        } else {
                                            expandedHistoryGroups.insert(group.key)
                                        }
                                    } label: {
                                        Text(expandedHistoryGroups.contains(group.key) ? "Show less" : "\(group.entries.count - 2) more")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color(hex: "4A9EFF"))
                                    }
                                }
                            }
                            .padding(.leading, 4)
                            .padding(.top, 8)

                            let visibleEntries = expandedHistoryGroups.contains(group.key) ? group.entries : Array(group.entries.prefix(2))
                            ForEach(visibleEntries) { entry in
                                historyRow(entry)
                            }
                        }
                    }
                }

                Spacer(minLength: 40)
            }
            .padding(.horizontal, 20)
        }
        .refreshable {
            await service.fetchHistory()
        }
    }

    private struct HistoryGroup: Identifiable {
        let key: String
        let entries: [AgentService.TaskHistoryEntry]
        var id: String { key }
    }

    private var groupedHistory: [HistoryGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: service.taskHistory) { entry -> String in
            guard let date = entry.date else { return "Unknown" }
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
        // Sort groups: Today first, then Yesterday, then by date descending
        let order = ["Today", "Yesterday"]
        return grouped.map { HistoryGroup(key: $0.key, entries: $0.value) }
            .sorted { a, b in
                let aIdx = order.firstIndex(of: a.key) ?? 99
                let bIdx = order.firstIndex(of: b.key) ?? 99
                if aIdx != bIdx { return aIdx < bIdx }
                return a.key > b.key
            }
    }

    private func historyRow(_ entry: AgentService.TaskHistoryEntry) -> some View {
        let isChat = entry.mode == "chat"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(entry.success ? .green : .red)
                    .font(.system(size: 16))

                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.task)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if let summary = entry.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 13))
                            .foregroundStyle(.gray)
                            .lineLimit(2)
                    }
                }

                Spacer()

                Button {
                    service.deleteHistoryEntry(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }

            HStack(spacing: 12) {
                // Mode indicator
                HStack(spacing: 4) {
                    Image(systemName: isChat ? "bubble.left.fill" : "gearshape.fill")
                        .font(.system(size: 9))
                    Text(isChat ? "Chat" : "Automation")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(isChat ? Color(hex: "4A9EFF").opacity(0.7) : .orange.opacity(0.7))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background((isChat ? Color(hex: "4A9EFF") : .orange).opacity(0.08))
                .clipShape(Capsule())

                if !isChat {
                    Label("\(entry.steps) steps", systemImage: "arrow.triangle.swap")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.7))
                    Label("\(entry.time)s", systemImage: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.7))
                }
                if let model = entry.model {
                    Label(model, systemImage: "cpu")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.7))
                }
            }

            if let date = entry.date {
                Text(date, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(.gray.opacity(0.5))
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedHistoryEntry = entry
        }
    }

    private var emptyHistoryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36))
                .foregroundStyle(.gray.opacity(0.4))
            Text("No history yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Chat conversations and automation tasks will appear here")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // notConnectedHistoryCard removed — history always loads locally

    // MARK: - Memory Tab

    private var memoryTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if service.memories.isEmpty && newMemoryText.isEmpty {
                        emptyMemoryCard
                    } else {
                        if !service.memories.isEmpty {
                            HStack {
                                Text("\(service.memories.count) facts")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.gray)
                                Spacer()
                            }
                            .padding(.leading, 4)
                        }

                        ForEach(service.memories) { memory in
                            memoryRow(memory)
                        }
                    }

                    Spacer(minLength: 60)
                }
                .padding(.horizontal, 20)
            }
            .refreshable {
                await service.fetchMemories()
            }

            // Add memory input bar
            HStack(spacing: 10) {
                TextField("Add a memory...", text: $newMemoryText)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Button {
                    let fact = newMemoryText.trimmingCharacters(in: .whitespaces)
                    guard !fact.isEmpty else { return }
                    newMemoryText = ""
                    assistant.saveMemoryFact(fact)
                    // Refresh the memory list
                    Task { await service.fetchMemories() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            newMemoryText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? .gray.opacity(0.3)
                                : Color(hex: "4A9EFF")
                        )
                }
                .disabled(newMemoryText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.black)
        }
    }

    private func memoryRow(_ memory: AgentService.MemoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(memory.fact)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .lineLimit(4)

            HStack {
                if let date = memory.date {
                    Text(date)
                        .font(.system(size: 11))
                        .foregroundStyle(.gray.opacity(0.5))
                }

                Spacer()

                Button {
                    editText = memory.fact
                    editingMemory = memory
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(hex: "4A9EFF"))
                }

                Button {
                    Task { await service.deleteMemory(memory) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - History Detail Sheet

    private func historyDetailSheet(_ entry: AgentService.TaskHistoryEntry) -> some View {
        let isChat = entry.mode == "chat"
        return ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    Image(systemName: entry.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.success ? .green : .red)
                    Text(entry.task)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Spacer()
                    Button("Done") { selectedHistoryEntry = nil }
                        .foregroundStyle(Color(hex: "4A9EFF"))
                }

                // Stats
                HStack(spacing: 16) {
                    // Mode badge
                    HStack(spacing: 4) {
                        Image(systemName: isChat ? "bubble.left.fill" : "gearshape.fill")
                            .font(.system(size: 9))
                        Text(isChat ? "Chat" : "Automation")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isChat ? Color(hex: "4A9EFF").opacity(0.8) : .orange.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background((isChat ? Color(hex: "4A9EFF") : .orange).opacity(0.1))
                    .clipShape(Capsule())

                    if !isChat {
                        Label("\(entry.steps) steps", systemImage: "arrow.triangle.swap")
                        Label("\(entry.time)s", systemImage: "clock")
                    }
                    if let model = entry.model {
                        Label(model, systemImage: "cpu")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.gray)

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Logs
                if let logs = entry.agentLogs, !logs.isEmpty {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(Color(hex: "4A9EFF"))
                            .font(.system(size: 12))
                        Text("Agent Logs (\(logs.count) lines)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.gray)
                        Spacer()
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = logs.joined(separator: "\n")
                        } label: {
                            Label("Copy All Logs", systemImage: "doc.on.clipboard")
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(logColor(line))
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.gray.opacity(0.3))
                        Text("No logs available")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray.opacity(0.5))
                        Text("No logs were recorded for this entry")
                            .font(.system(size: 12))
                            .foregroundStyle(.gray.opacity(0.3))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.large])
    }

    private func chatDetailSheet(_ message: AssistantService.ChatMessage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                // Header
                HStack {
                    if let provider = message.provider {
                        Text(provider == "apple" ? "Apple" : provider == "openai" ? "GPT-5.4" : "Gemini")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: "4A9EFF"))
                    }
                    Spacer()
                    Button("Done") { selectedChatMessage = nil }
                        .foregroundStyle(Color(hex: "4A9EFF"))
                }

                // Timestamp
                HStack {
                    Image(systemName: "clock")
                        .font(.system(size: 12))
                    Text(message.timestamp, style: .date)
                        .font(.system(size: 12))
                    Text(message.timestamp, style: .time)
                        .font(.system(size: 12))
                    Spacer()
                }
                .foregroundStyle(.gray)

                // Tools used
                if let tools = message.toolsUsed, !tools.isEmpty {
                    HStack {
                        Image(systemName: "wrench.fill")
                            .foregroundStyle(.orange)
                            .font(.system(size: 12))
                        Text("Tools Used (\(tools.count))")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.gray)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tools, id: \.self) { tool in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(.orange.opacity(0.5))
                                    .frame(width: 6, height: 6)
                                Text(tool)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                // Full response
                HStack {
                    Image(systemName: "text.bubble.fill")
                        .foregroundStyle(Color(hex: "4A9EFF"))
                        .font(.system(size: 12))
                    Text("Response")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.gray)
                    Spacer()
                }

                Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Agent Logs
                if let logs = message.logs, !logs.isEmpty {
                    HStack {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(Color(hex: "4A9EFF"))
                            .font(.system(size: 12))
                        Text("Agent Logs (\(logs.count) lines)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.gray)
                        Spacer()
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = logs.joined(separator: "\n")
                        } label: {
                            Label("Copy All Logs", systemImage: "doc.on.clipboard")
                        }
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(logColor(line))
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.gray.opacity(0.3))
                        Text("No logs available")
                            .font(.system(size: 14))
                            .foregroundStyle(.gray.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.large])
    }

    private func editMemorySheet(_ memory: AgentService.MemoryEntry) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                HStack {
                    Text("Edit Memory")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button("Cancel") { editingMemory = nil }
                        .foregroundStyle(.gray)
                }

                TextEditor(text: $editText)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 120)

                Button {
                    Task {
                        await service.editMemory(memory, newFact: editText)
                        editingMemory = nil
                    }
                } label: {
                    Text("Save")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Color(hex: "4A9EFF").opacity(0.15))
                        .foregroundStyle(Color(hex: "4A9EFF"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Spacer()
            }
            .padding(20)
        }
        .presentationDetents([.medium])
    }

    private var emptyMemoryCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 36))
                .foregroundStyle(.gray.opacity(0.4))
            Text("No memories yet")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Tell me things to remember in the Chat tab — like names, dates, or preferences")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // notConnectedMemoryCard removed — memories always load locally

    // MARK: - Connection Dot

    private var connectionDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(service.isPolling ? (service.currentState?.isActive == true ? Color.green : Color(hex: "4A9EFF")) : Color.gray.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(service.isPolling ? (service.currentState?.isActive == true ? "Active" : "Connected") : "Offline")
                .font(.caption)
                .foregroundStyle(service.isPolling ? .white.opacity(0.7) : .gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
        .clipShape(Capsule())
    }

    // MARK: - Connection Card

    private var connectionCard: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(Color(hex: "4A9EFF"))
                    .font(.system(size: 14))
                Text("Server")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.gray)
                Spacer()
            }

            TextField("Bryans-MacBook-Pro.local", text: $serverAddress)
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Button(action: toggleConnection) {
                HStack {
                    Image(systemName: service.isPolling ? "stop.fill" : "bolt.fill")
                        .font(.system(size: 13))
                    Text(service.isPolling ? "Disconnect" : "Connect")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(service.isPolling ? Color.red.opacity(0.15) : Color(hex: "4A9EFF").opacity(0.15))
                .foregroundStyle(service.isPolling ? .red : Color(hex: "4A9EFF"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Active Agent Card

    private func activeAgentCard(_ state: AgentStatusResponse) -> some View {
        VStack(spacing: 18) {
            HStack {
                phaseIcon(state.phase)
                    .font(.system(size: 14))
                    .foregroundStyle(phaseColor(state.phase))
                Text(phaseLabel(state.phase))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(phaseColor(state.phase))
                Spacer()
                Text("\(state.elapsed)s")
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.gray)
            }

            Text(state.taskName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 8) {
                HStack {
                    Text("Step \(state.currentStep) of \(state.totalSteps)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Spacer()
                    if !state.toolName.isEmpty {
                        Text(state.toolName)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(phaseColor(state.phase).opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(phaseColor(state.phase).opacity(0.1))
                            .clipShape(Capsule())
                    }
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.08))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(phaseColor(state.phase))
                            .frame(width: geo.size.width * CGFloat(state.currentStep) / CGFloat(max(state.totalSteps, 1)), height: 6)
                            .animation(.easeInOut(duration: 0.3), value: state.currentStep)
                    }
                }
                .frame(height: 6)
            }

            if !state.thought.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "4A9EFF"))
                        .padding(.top, 2)
                    Text(state.thought)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(phaseColor(state.phase).opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - Completion Card

    private func completionCard(_ state: AgentStatusResponse) -> some View {
        VStack(spacing: 16) {
            Image(systemName: state.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(state.success ? .green : .red)
            Text(state.success ? "Task Complete" : "Task Failed")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
            if !state.thought.isEmpty {
                Text(state.thought)
                    .font(.system(size: 14))
                    .foregroundStyle(.gray)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            HStack(spacing: 20) {
                Label("\(state.currentStep) steps", systemImage: "arrow.triangle.swap")
                Label("\(state.elapsed)s", systemImage: "clock")
            }
            .font(.caption)
            .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Idle / Connecting / Get Started

    private var idleCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(Color(hex: "4A9EFF").opacity(0.5))
            Text("Waiting for task")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text("Hold the Action Button and speak a command")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var connectingCard: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Color(hex: "4A9EFF"))
                .scaleEffect(1.2)
            Text("Connecting to server...")
                .font(.subheadline)
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var getStartedCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 36))
                .foregroundStyle(.gray.opacity(0.4))
            Text("Not connected")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("Enter your Mac's hostname above and tap Connect")
                .font(.system(size: 14))
                .foregroundStyle(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    // MARK: - Helpers

    private func toggleConnection() {
        if service.isPolling {
            service.stopPolling()
        } else {
            let ip = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ip.isEmpty else { return }
            service.serverURL = "http://\(ip):8000"
            service.startPolling()
        }
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "thinking": return Color(hex: "4A9EFF")
        case "acting": return .orange
        case "observing": return .purple
        case "complete": return .green
        case "failed": return .red
        case "waiting": return .yellow
        default: return .gray
        }
    }

    private func phaseIcon(_ phase: String) -> Image {
        switch phase {
        case "thinking": return Image(systemName: "brain.head.profile")
        case "acting": return Image(systemName: "bolt.fill")
        case "observing": return Image(systemName: "eye.fill")
        case "complete": return Image(systemName: "checkmark.circle.fill")
        case "failed": return Image(systemName: "xmark.circle.fill")
        case "waiting": return Image(systemName: "person.fill.questionmark")
        default: return Image(systemName: "circle.fill")
        }
    }

    private func phaseLabel(_ phase: String) -> String {
        switch phase {
        case "thinking": return "Thinking"
        case "acting": return "Acting"
        case "observing": return "Observing"
        case "complete": return "Complete"
        case "failed": return "Failed"
        case "waiting": return "Waiting for you"
        default: return phase.capitalized
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, opacity: 1)
    }
}

#Preview {
    ContentView()
}
