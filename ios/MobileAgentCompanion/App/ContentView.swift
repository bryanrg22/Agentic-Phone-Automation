import SwiftUI

struct ContentView: View {
    @State private var service = AgentService()
    @AppStorage("serverAddress") private var serverAddress: String = ""
    @State private var isEditing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
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
                        connectionDot
                    }
                    .padding(.top, 8)

                    // Connection Card
                    connectionCard

                    // Main Content
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

                    Spacer(minLength: 40)
                }
                .padding(.horizontal, 20)
            }
        }
    }

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
                .padding(14)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

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

    private func activeAgentCard(_ state: AgentService.AgentStatusResponse) -> some View {
        VStack(spacing: 18) {
            // Phase indicator
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

            // Task name
            VStack(alignment: .leading, spacing: 8) {
                Text(state.taskName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Step progress
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
                            .frame(
                                width: geo.size.width * CGFloat(state.currentStep) / CGFloat(max(state.totalSteps, 1)),
                                height: 6
                            )
                            .animation(.easeInOut(duration: 0.3), value: state.currentStep)
                    }
                }
                .frame(height: 6)
            }

            // Agent thought
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

    private func completionCard(_ state: AgentService.AgentStatusResponse) -> some View {
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
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

#Preview {
    ContentView()
}
