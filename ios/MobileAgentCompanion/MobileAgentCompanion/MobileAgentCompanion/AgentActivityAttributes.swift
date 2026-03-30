import ActivityKit
import Foundation

struct AgentActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var currentStep: Int
        var totalSteps: Int
        var thought: String
        var phase: String       // thinking, acting, observing, complete, failed, waiting
        var elapsed: String
        var isComplete: Bool
        var success: Bool
        var waitingForInput: Bool
        var inputQuestion: String
        var inputOptions: [String]
    }

    var taskName: String
}
