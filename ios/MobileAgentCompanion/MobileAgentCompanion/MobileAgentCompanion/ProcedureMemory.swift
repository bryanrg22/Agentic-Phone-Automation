import Foundation

// MARK: - Procedural Memory System
//
// Learns reusable action sequences from successful task completions.
// Stores on-device as JSONL. No database, no cloud infrastructure.
//
// Research backing:
//   - ReMe (arXiv:2512.10696): scenario-based indexing, utility-based pruning
//   - AppAgentX (arXiv:2503.02268): mobile agent shortcut extraction from trajectories
//   - Voyager (arXiv:2305.16291): skill library with description + index
//   - MACLA (arXiv:2512.18950): Bayesian reliability, contrastive refinement
//   - SoK Agent Skills (arXiv:2602.20867): hint injection > blind replay

// MARK: - Data Structures

/// A single tool call with its arguments, result, and timing.
struct ToolTrace: Codable {
    let tool: String
    let args: [String: String]
    let result: String
    let target: String?
    let time: Double
}

/// One step in the agent loop — may contain multiple tool calls.
struct StepTrace: Codable {
    let step: Int
    let tools: [ToolTrace]
    let aiTime: Double
}

/// Trust tier for procedure execution (SoK survey trust tiers).
enum TrustTier: String, Codable {
    case hint      // Inject as suggestion, full verification each step
    case trusted   // Skip intermediate screenshots, faster execution
    case prune     // Unreliable — should be deleted
}

/// A learned procedure extracted from successful task completions.
struct Procedure: Codable {
    let id: UUID
    let scenario: String
    let pattern: String
    let steps: [ToolTrace]
    var successCount: Int
    var failCount: Int
    let createdAt: Date
    var lastUsed: Date?

    var reliability: Double {
        let total = successCount + failCount
        guard total > 0 else { return 0 }
        return Double(successCount) / Double(total)
    }

    var trustTier: TrustTier {
        let total = successCount + failCount
        if total < 2 { return .hint }
        if total >= 5 && reliability < 0.5 { return .prune }
        if reliability >= 0.8 && successCount >= 3 { return .trusted }
        return .hint
    }
}

// MARK: - Procedure Memory Manager

final class ProcedureMemory {
    static let shared = ProcedureMemory()

    private var procedures: [Procedure] = []
    private var loaded = false

    private var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("procedures/procedures.jsonl")
    }

    // MARK: - Load / Save

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            procedures = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        procedures = text.split(separator: "\n").compactMap { line in
            try? decoder.decode(Procedure.self, from: Data(line.utf8))
        }

        // Auto-prune unreliable procedures
        let before = procedures.count
        procedures.removeAll { $0.trustTier == .prune }
        if procedures.count < before {
            save()
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = procedures.compactMap { p -> String? in
            guard let data = try? encoder.encode(p) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let content = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Query

    /// Get all procedure scenarios for LLM matching.
    /// Returns [(id, scenario, pattern, reliability, trustTier)] for the matching prompt.
    func allScenarios() -> [(id: UUID, scenario: String, pattern: String, reliability: Double, tier: TrustTier)] {
        loadIfNeeded()
        return procedures.map { ($0.id, $0.scenario, $0.pattern, $0.reliability, $0.trustTier) }
    }

    /// Get a procedure by ID.
    func procedure(for id: UUID) -> Procedure? {
        loadIfNeeded()
        return procedures.first { $0.id == id }
    }

    /// Build the prompt injection text for a matched procedure.
    func promptInjection(for procedure: Procedure) -> String {
        let tierLabel = procedure.trustTier == .trusted ? "high" : "developing"
        let total = procedure.successCount + procedure.failCount
        let stepsText = procedure.steps.enumerated().map { i, step in
            var line = "\(i + 1). \(step.tool)"
            if !step.args.isEmpty {
                let argStr = step.args.map { "\($0.key): \"\($0.value)\"" }.joined(separator: ", ")
                line += "(\(argStr))"
            }
            if let target = step.target {
                line += " — target: \"\(target)\""
            }
            return line
        }.joined(separator: "\n")

        return """
        <LEARNED_PROCEDURE confidence="\(tierLabel)" uses="\(procedure.successCount)/\(total) successful">
        You've completed this type of task before. These steps worked:
        \(stepsText)

        Follow this plan. Adapt if the screen looks different than expected.
        If the UI looks different than expected, fall back to normal exploration.
        \(procedure.trustTier == .trusted ? "This procedure is trusted — you can move quickly without extra verification between steps." : "Verify each step with the auto-captured screenshot before proceeding.")
        </LEARNED_PROCEDURE>
        """
    }

    // MARK: - Record Success / Failure

    /// Record that a procedure was used successfully.
    func recordSuccess(id: UUID) {
        loadIfNeeded()
        guard let idx = procedures.firstIndex(where: { $0.id == id }) else { return }
        procedures[idx].successCount += 1
        procedures[idx].lastUsed = Date()
        save()
    }

    /// Record that a procedure was used but the task failed or deviated.
    func recordFailure(id: UUID) {
        loadIfNeeded()
        guard let idx = procedures.firstIndex(where: { $0.id == id }) else { return }
        procedures[idx].failCount += 1
        procedures[idx].lastUsed = Date()
        save()
        // Re-check pruning
        if procedures[idx].trustTier == .prune {
            procedures.remove(at: idx)
            save()
        }
    }

    // MARK: - Add New Procedure

    /// Store a newly extracted procedure.
    func addProcedure(scenario: String, pattern: String, steps: [ToolTrace]) {
        loadIfNeeded()
        let proc = Procedure(
            id: UUID(),
            scenario: scenario,
            pattern: pattern,
            steps: steps,
            successCount: 1,  // It just succeeded
            failCount: 0,
            createdAt: Date(),
            lastUsed: Date()
        )
        procedures.append(proc)
        save()
    }

    /// Update an existing procedure's steps (contrastive refinement — when a better path is found).
    func updateSteps(id: UUID, newSteps: [ToolTrace]) {
        loadIfNeeded()
        guard let idx = procedures.firstIndex(where: { $0.id == id }) else { return }
        let existing = procedures[idx]
        procedures[idx] = Procedure(
            id: existing.id,
            scenario: existing.scenario,
            pattern: existing.pattern,
            steps: newSteps,
            successCount: existing.successCount,
            failCount: existing.failCount,
            createdAt: existing.createdAt,
            lastUsed: Date()
        )
        save()
    }

    // MARK: - Build Matching Prompt

    /// Build the prompt to ask the LLM which procedure matches a new task.
    /// Returns nil if there are no procedures to match against.
    func buildMatchingPrompt(task: String) -> String? {
        loadIfNeeded()
        guard !procedures.isEmpty else { return nil }

        let entries = procedures.enumerated().map { i, p in
            "\(i + 1). [id: \(p.id.uuidString.prefix(8))] Scenario: \"\(p.scenario)\" | Pattern: \"\(p.pattern)\" | Reliability: \(Int(p.reliability * 100))% (\(p.successCount)/\(p.successCount + p.failCount))"
        }.joined(separator: "\n")

        return """
        Here are procedures I've learned from past successful tasks:
        \(entries)

        New task: "\(task)"

        Does any procedure match this task? If yes, return ONLY the id (first 8 characters). If no match, return ONLY "none".
        """
    }

    /// Parse the LLM's match response and return the matched procedure.
    func parseMatch(response: String) -> Procedure? {
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if cleaned == "none" || cleaned.contains("none") { return nil }

        // Find any procedure whose ID prefix appears in the response
        for proc in procedures {
            let prefix = String(proc.id.uuidString.prefix(8)).lowercased()
            if cleaned.contains(prefix) {
                return proc
            }
        }
        return nil
    }

    // MARK: - Build Extraction Prompt

    /// Build the prompt to extract a procedure from a successful task trace.
    func buildExtractionPrompt(task: String, trace: [StepTrace]) -> String {
        let stepsText = trace.map { step in
            let tools = step.tools.map { t in
                var desc = t.tool
                if !t.args.isEmpty {
                    let argStr = t.args.map { "\($0.key): \"\($0.value)\"" }.joined(separator: ", ")
                    desc += "(\(argStr))"
                }
                if let target = t.target { desc += " [target: \(target)]" }
                return desc
            }.joined(separator: ", ")
            return "Step \(step.step): \(tools)"
        }.joined(separator: "\n")

        return """
        I just completed this task successfully:
        Task: "\(task)"
        Action sequence:
        \(stepsText)

        Extract a reusable procedure. Return a JSON object with these fields:
        - "scenario": When should this procedure be reused? (e.g., "User wants to send a text message to a specific contact")
        - "pattern": The task pattern with variables in curly braces (e.g., "text {contact} {message}")
        - "steps": Array of the essential tool calls, with specific values replaced by {variable} names where they should change per-use. Each step: {"tool": "...", "args": {"key": "{variable_or_literal}"}, "target": "...or null"}

        Return ONLY valid JSON, no other text.
        """
    }

    /// Parse the LLM's extraction response and store the new procedure.
    /// Returns true if a procedure was successfully extracted and stored.
    @discardableResult
    func parseAndStore(extractionResponse: String, fallbackTask: String) -> Bool {
        // Try to extract JSON from the response (handle markdown code blocks)
        var jsonStr = extractionResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        if let startRange = jsonStr.range(of: "```json") {
            jsonStr = String(jsonStr[startRange.upperBound...])
            if let endRange = jsonStr.range(of: "```") {
                jsonStr = String(jsonStr[..<endRange.lowerBound])
            }
        } else if let startRange = jsonStr.range(of: "```") {
            jsonStr = String(jsonStr[startRange.upperBound...])
            if let endRange = jsonStr.range(of: "```") {
                jsonStr = String(jsonStr[..<endRange.lowerBound])
            }
        }
        jsonStr = jsonStr.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scenario = json["scenario"] as? String,
              let pattern = json["pattern"] as? String else {
            return false
        }

        // Parse steps
        var steps: [ToolTrace] = []
        if let stepsArr = json["steps"] as? [[String: Any]] {
            for s in stepsArr {
                let tool = s["tool"] as? String ?? ""
                let argsDict = s["args"] as? [String: Any] ?? [:]
                let args = argsDict.mapValues { "\($0)" }
                let target = s["target"] as? String
                steps.append(ToolTrace(tool: tool, args: args, result: "", target: target, time: 0))
            }
        }

        guard !steps.isEmpty else { return false }

        // Check for duplicate scenarios (don't add if very similar procedure exists)
        let existingScenarios = procedures.map { $0.scenario.lowercased() }
        let newLower = scenario.lowercased()
        for existing in existingScenarios {
            // Simple overlap check — if >60% of words match, it's likely a duplicate
            let newWords = Set(newLower.split(separator: " ").map(String.init))
            let existWords = Set(existing.split(separator: " ").map(String.init))
            let overlap = newWords.intersection(existWords).count
            let maxCount = max(newWords.count, existWords.count)
            if maxCount > 0 && Double(overlap) / Double(maxCount) > 0.6 {
                return false // Duplicate — skip
            }
        }

        addProcedure(scenario: scenario, pattern: pattern, steps: steps)
        return true
    }

    // MARK: - Stats

    var count: Int {
        loadIfNeeded()
        return procedures.count
    }
}
