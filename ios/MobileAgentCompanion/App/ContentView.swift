import SwiftUI

struct ContentView: View {
    @State private var service = AgentService()
    @AppStorage("serverAddress") private var serverAddress: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Server Connection") {
                    TextField("Mac IP (e.g. 192.168.1.42)", text: $serverAddress)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button(action: toggleConnection) {
                        HStack {
                            Image(systemName: service.isPolling ? "wifi.slash" : "wifi")
                            Text(service.isPolling ? "Disconnect" : "Connect")
                        }
                    }
                    .tint(service.isPolling ? .red : .blue)
                }

                if service.isPolling {
                    Section("Status") {
                        if let state = service.currentState {
                            HStack {
                                Circle()
                                    .fill(state.isActive ? Color.green : Color.gray)
                                    .frame(width: 10, height: 10)
                                Text(state.isActive ? "Agent Running" : "Idle")
                                    .foregroundStyle(.secondary)
                            }

                            if state.isActive {
                                LabeledContent("Task", value: state.taskName)
                                LabeledContent("Step", value: "\(state.currentStep)/\(state.totalSteps)")
                                LabeledContent("Phase", value: state.phase.capitalized)
                                LabeledContent("Time", value: "\(state.elapsed)s")

                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Agent Thought")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(state.thought)
                                        .font(.callout)
                                }

                                ProgressView(
                                    value: Double(state.currentStep),
                                    total: Double(max(state.totalSteps, 1))
                                )
                                .tint(phaseColor(state.phase))
                            }
                        } else {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text("Connecting...")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("mobile-use")
        }
    }

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
        case "thinking": return .blue
        case "acting": return .orange
        case "observing": return .purple
        case "complete": return .green
        case "failed": return .red
        default: return .gray
        }
    }
}

#Preview {
    ContentView()
}
