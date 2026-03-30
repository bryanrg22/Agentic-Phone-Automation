import ActivityKit
import SwiftUI
import WidgetKit

struct AgentWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            // ─── Lock Screen Banner ───
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: phaseIcon(context.state.phase))
                        .font(.title3)
                        .foregroundColor(phaseColor(context.state.phase))

                    Text(context.attributes.taskName)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer()

                    Text("\(context.state.currentStep)/\(context.state.totalSteps)")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                        .foregroundColor(phaseColor(context.state.phase))
                }

                Text(context.state.thought)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                HStack(spacing: 12) {
                    ProgressView(
                        value: Double(context.state.currentStep),
                        total: Double(max(context.state.totalSteps, 1))
                    )
                    .tint(phaseColor(context.state.phase))

                    Text("\(context.state.elapsed)s")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            .padding()

        } dynamicIsland: { context in
            DynamicIsland {
                // ─── Expanded View ───
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: phaseIcon(context.state.phase))
                        .font(.title2)
                        .foregroundColor(phaseColor(context.state.phase))
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text("\(context.state.currentStep)/\(context.state.totalSteps)")
                            .font(.title3)
                            .fontWeight(.bold)
                            .monospacedDigit()
                        Text("\(context.state.elapsed)s")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.taskName)
                        .font(.headline)
                        .lineLimit(1)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.thought)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)

                        ProgressView(
                            value: Double(context.state.currentStep),
                            total: Double(max(context.state.totalSteps, 1))
                        )
                        .tint(phaseColor(context.state.phase))
                    }
                    .padding(.horizontal, 4)
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
                // ─── Minimal (multiple activities) ───
                Image(systemName: phaseIcon(context.state.phase))
                    .foregroundColor(phaseColor(context.state.phase))
            }
        }
    }

    // ─── Helpers ───

    private func phaseIcon(_ phase: String) -> String {
        switch phase {
        case "thinking": return "brain.head.profile"
        case "acting": return "bolt.fill"
        case "observing": return "eye.fill"
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
        isComplete: false, success: false
    )
    AgentActivityAttributes.ContentState(
        currentStep: 7, totalSteps: 7,
        thought: "Task completed!",
        phase: "complete", elapsed: "28.1",
        isComplete: true, success: true
    )
}
