import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct AgentWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            // ─── Lock Screen Banner ───
            VStack(spacing: 12) {
                // Top: icon + task name + step count
                HStack(spacing: 10) {
                    Image(systemName: phaseIcon(context.state.phase))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(phaseColor(context.state.phase))

                    Text(context.attributes.taskName)
                        .font(.system(.subheadline, weight: .semibold))
                        .lineLimit(1)

                    Spacer()

                    Text("\(context.state.elapsed)s")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Status text
                Text(context.state.thought)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Progress bar with step label
                HStack(spacing: 8) {
                    ProgressView(
                        value: Double(context.state.currentStep),
                        total: Double(max(context.state.totalSteps, 1))
                    )
                    .tint(phaseColor(context.state.phase))

                    Text("\(context.state.currentStep)/\(context.state.totalSteps)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Stop button
                if !context.state.isComplete {
                    Button(intent: StopAgentIntent()) {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10))
                            Text("Stop")
                                .font(.system(.caption, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

        } dynamicIsland: { context in
            DynamicIsland {
                // ─── Expanded View ───
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: phaseIcon(context.state.phase))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(phaseColor(context.state.phase))
                        .padding(.leading, 2)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    if !context.state.isComplete {
                        Button(intent: StopAgentIntent()) {
                            ZStack {
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: 2.5)
                                    .frame(width: 36, height: 36)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.red)
                                    .frame(width: 14, height: 14)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.green)
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if context.state.waitingForInput {
                        Text(context.state.inputQuestion)
                            .font(.system(.subheadline, weight: .bold))
                            .lineLimit(2)
                    } else {
                        Text(context.state.thought)
                            .font(.system(.subheadline, weight: .bold))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.bottom, priority: context.state.waitingForInput ? 2 : 1) {
                    if context.state.waitingForInput {
                        // Question UI — compact option buttons
                        VStack(spacing: 4) {
                            ForEach(context.state.inputOptions.prefix(4), id: \.self) { option in
                                Button(intent: RespondToAgentIntent(choice: option)) {
                                    Text(option)
                                        .font(.system(.caption2, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .contentMargins(.all, 0)
                        .padding(.horizontal, 2)
                    } else {
                        VStack(spacing: 8) {
                            // Task name + elapsed time
                            HStack {
                                Text(context.attributes.taskName)
                                    .font(.system(.caption, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(context.state.elapsed)s")
                                    .font(.system(.caption2, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }

                            // Progress bar with step count
                            HStack(spacing: 8) {
                                ProgressView(
                                    value: Double(context.state.currentStep),
                                    total: Double(max(context.state.totalSteps, 1))
                                )
                                .tint(phaseColor(context.state.phase))

                                Text("\(context.state.currentStep)/\(context.state.totalSteps)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 2)
                    }
                }

            } compactLeading: {
                // ─── Compact Left ───
                HStack(spacing: 4) {
                    Image(systemName: phaseIcon(context.state.phase))
                        .foregroundColor(phaseColor(context.state.phase))
                    Text("\(context.state.currentStep)/\(context.state.totalSteps)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }

            } compactTrailing: {
                // ─── Compact Right ───
                Text(shortThought(context.state.thought))
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 80)

            } minimal: {
                // ─── Minimal ───
                Image(systemName: phaseIcon(context.state.phase))
                    .foregroundColor(phaseColor(context.state.phase))
            }
            .keylineTint(context.state.waitingForInput ? .yellow : .clear)
        }
    }

    // ─── Helpers ───

    private func phaseIcon(_ phase: String) -> String {
        switch phase {
        case "thinking": return "brain.head.profile"
        case "acting": return "bolt.fill"
        case "observing": return "eye.fill"
        case "waiting": return "questionmark.circle.fill"
        case "complete": return "checkmark.circle.fill"
        case "failed": return "xmark.circle.fill"
        default: return "circle.dotted"
        }
    }

    private func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "thinking": return .blue
        case "acting": return .orange
        case "observing": return .purple
        case "waiting": return .yellow
        case "complete": return .green
        case "failed": return .red
        default: return .gray
        }
    }

    private func shortThought(_ thought: String) -> String {
        if thought.count <= 20 { return thought }
        return String(thought.prefix(18)) + "..."
    }
}

// ─── Previews ───

extension AgentActivityAttributes {
    static var preview: AgentActivityAttributes {
        AgentActivityAttributes(taskName: "Search for tacos in LA")
    }
}

#Preview("Live Activity", as: .content, using: AgentActivityAttributes.preview) {
    AgentWidgetExtensionLiveActivity()
} contentStates: {
    AgentActivityAttributes.ContentState(
        currentStep: 3, totalSteps: 7,
        thought: "Tapping 'Search' button...",
        phase: "acting", elapsed: "12.4",
        isComplete: false, success: false,
        waitingForInput: false, inputQuestion: "", inputOptions: []
    )
    AgentActivityAttributes.ContentState(
        currentStep: 7, totalSteps: 7,
        thought: "Task completed!",
        phase: "complete", elapsed: "28.1",
        isComplete: true, success: true,
        waitingForInput: false, inputQuestion: "", inputOptions: []
    )
}
