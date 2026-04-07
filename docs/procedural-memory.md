# Procedural Memory: Learning from Repeated Tasks

**Date:** April 6, 2026

How the agent learns from successful task executions and reuses that knowledge to complete future similar tasks faster, with fewer steps and fewer errors.

## The Three Layers

These are three layers of the same system, not three separate features:

| Layer | What it remembers | Example |
|-------|-------------------|---------|
| **Adaptive task memory** | The *workflow* (which tools, which order) | "To text someone: open Messages, tap contact, typeAndSubmit" |
| **Procedural skill learning** | *Micro-actions* within workflows (coordinates, gestures, timing) | "In this drag-and-drop game, grab at (30%, 50%), release at (70%, 20%)" |
| **Shortcut Copilot** | Nothing — *graduates* a learned workflow into a native iOS Shortcut | "You've texted Emiliano 5 times. Want me to make a Shortcut for that?" |

In practice, one system handles adaptive task memory and procedural skills together. The Shortcut Copilot is an optional output layer — the agent proposes a native automation after detecting a repeated pattern, making itself unnecessary for that task.

## Current State

### What we already have

- **`agentLogs`** saved to `tasks.jsonl` on-device (`OnDeviceAgent.swift` line 1059) — the `HistoryEntry` already includes the full `logs` array with every `[Tool] toolName` line from the run.
- **`recentActions`** array tracks tool calls during a run for stuck detection.
- **`rollingSummary`** maintains a per-step summary of which tools were called.
- **Semantic memory** (`memories/user.md`) — persistent facts about the user, loaded into every session.
- **Episodic memory** (`logs/tasks.jsonl`) — task history with summary-level data (task, steps, time, success/fail).

### What's missing

The `agentLogs` field is unstructured log strings like `"[Tool] tap"`, `"[AI] Responded in 2.1s"`. It's not a clean sequence of `{tool, args, target, result}` that can be compared, generalized, or replayed.

On `agent.mjs` (Mac side), it's worse — no tool calls logged at all, just `{task, steps, time, success}`.

**There is no mechanism to:**
1. Extract reusable procedures from successful runs
2. Match incoming tasks against known procedures
3. Inject learned procedures into the agent's planning
4. Track procedure reliability over time

## Research

### Directly relevant systems

**AppAgentX** (arXiv:2503.02268) — the closest existing system. A mobile agent that builds a graph of page transitions and creates "shortcuts" (multi-step action sequences). Uses Neo4j graph database for page transitions, Pinecone vector database for element embeddings, and ResNet50 for visual matching. Post-execution trajectory analysis decomposes runs into overlapping triples (source page -> action -> target page) and detects repetitive patterns via LLM judgment. Too heavy for on-device — we need a file-based alternative.
- GitHub: https://github.com/Westlake-AGI-Lab/AppAgentX

**ReMe** (arXiv:2512.10696) — "Remember Me, Refine Me." Each experience is a tuple `(scenario, content, keywords, confidence, tools)` stored in a vector database indexed by "scenario" (when to use this). Key finding: **indexing by "when to use" outperformed "what it does" in all ablations.** Uses cosine similarity for retrieval, LLM rewriter to adapt retrieved experience to current task, and utility-based pruning (delete when `uses >= 5` and `success_rate <= 0.5`). Only successful trajectories get distilled.
- GitHub: https://github.com/agentscope-ai/ReMe

**Voyager** (MineDojo, arXiv:2305.16291) — simplest proven approach. Each skill is 3 files: executable code, text description, and index entry. Uses ChromaDB for embedding-based retrieval. After successful task completion, the code is extracted, described by LLM, embedded, and stored. The LLM can compose retrieved skills into new programs. Proven at scale in Minecraft.
- GitHub: https://github.com/MineDojo/Voyager

**MACLA** (arXiv:2512.18950) — hierarchical procedural memory with Bayesian reliability tracking. Procedures are `(goal, preconditions, action_sequence, postconditions)` with Beta distribution parameters (alpha=successes, beta=failures). Meta-procedures compose sub-procedures with control policies `{continue, skip, repeat, abort}`. Contrastive refinement activates when a procedure has >= 3 successes AND >= 3 failures — LLM compares success vs failure contexts to specialize the procedure. Build time: 56 seconds for 2851 trajectories -> 187 procedures.

### Key research findings

**Agent Skills Survey (SoK, arXiv:2602.20867):**
> "Curated skills raise agent pass rates by 16.2 pp on average, while self-generated skills degrade performance by 1.3 pp."

This means we must **not** blindly replay learned procedures. The correct approach is hint injection — the agent uses the procedure as a guide but verifies each step against the actual screen. Trust builds over time.

**Trust tier progression (from the survey):**
1. Metadata only — agent knows the procedure exists
2. Instruction access — agent reads the full procedure
3. Supervised execution — human confirms before replay
4. Autonomous execution — promoted after multiple successful supervised runs

**Rabbit R1 Teach Mode** (commercial) — user records a browser session, processing takes 3-6 minutes. Uses "hierarchical UI element detection" to adapt when layouts change between recording and replay. Users can annotate individual steps as needing LLM interpretation rather than blind replay. Matching is keyword/phrase-based from voice input.

**OpenClaw** — plain Markdown files in the workspace. Procedural knowledge is text instructions, always loaded into the system prompt. No automatic procedure extraction. Proves that markdown + file-based storage is sufficient for personal agents, but the gap is automatic learning.

### Storage format comparison

| System | Storage | Retrieval | Infrastructure |
|--------|---------|-----------|---------------|
| AppAgentX | Neo4j + Pinecone | Visual embeddings (ResNet50) | Heavy (2 databases + ML model) |
| ReMe | Vector DB | Cosine similarity on scenario embeddings | Medium (vector DB) |
| Voyager | Files (code + description + index) | ChromaDB embeddings | Light (local vector store) |
| MACLA | In-memory tuples | Nearest-neighbor on embeddings | Light |
| OpenClaw | Markdown files | Always in context | None |
| **Our approach** | JSONL files on iPhone | LLM classification or Apple NL embeddings | None |

## Implementation Plan (On-Device)

Everything runs on the iPhone. No databases, no cloud services beyond the LLM API, no external dependencies. JSONL files in the app's Documents directory.

### Step 1: Rich tool call logging (foundation)

Modify the agent loop in `OnDeviceAgent.swift` to record structured tool calls per step instead of just log strings.

**New data structure:**

```swift
struct ToolTrace: Codable {
    let tool: String           // "tap", "typeAndSubmit", "openApp", etc.
    let args: [String: String] // simplified string args
    let result: String         // first 100 chars of tool result
    let target: String?        // accessibility label if tapping a UI element
    let time: Double           // execution time in seconds
}

struct StepTrace: Codable {
    let step: Int
    let tools: [ToolTrace]
    let aiTime: Double         // LLM response time
}
```

During the agent loop, build a `[StepTrace]` array alongside the existing `rollingSummary`. Each step records which tools were called, with what arguments, what the result was, and what UI element was targeted.

On task completion, save the full trace in the `HistoryEntry`:

```swift
private struct HistoryEntry: Codable {
    // ... existing fields ...
    let trace: [StepTrace]?    // NEW: full tool call sequence
}
```

This is the foundation — without structured traces, nothing else works.

### Step 2: Procedure extraction (after successful task)

After `taskComplete`, if the task succeeded, make one additional LLM call to extract a reusable procedure:

**Prompt:**
```
Given this task and the action sequence that completed it:
Task: "{task}"
Steps: {trace}

Generate:
1. A "scenario" description: when should this procedure be reused? (e.g., "User wants to send a text message to a specific contact")
2. A "pattern" with variables: (e.g., "text {contact} {message}")
3. The essential steps with specific values replaced by variable names where appropriate.

Return as JSON.
```

**Stored procedure:**

```swift
struct Procedure: Codable {
    let id: UUID
    let scenario: String        // "User wants to send a text message to someone"
    let pattern: String         // "text {contact} {message}"
    let steps: [ToolTrace]      // the generalized action sequence
    var successCount: Int       // Bayesian tracking (MACLA-inspired)
    var failCount: Int
    let createdAt: Date
    var lastUsed: Date?
}
```

Saved to `Documents/procedures/procedures.jsonl`. One line per procedure.

**When to extract:** Not every successful task. Only when:
- The task completed successfully
- The task took 3+ steps (trivial tasks don't need procedures)
- No existing procedure matches the task (avoid duplicates)

### Step 3: Matching incoming tasks to known procedures

When a new task arrives, before entering the agent loop, check for matching procedures.

**Phase 1 (simple, immediate):** Send the task description + all procedure scenarios to the LLM:

```
Here are known procedures:
1. [id: abc] Scenario: "User wants to send a text message to someone"
2. [id: def] Scenario: "User wants to search for a location on Maps"
3. [id: ghi] Scenario: "User wants to play a round of Pinpoint"

New task: "text Kenny hey what's up"

Which procedure matches? Return the ID, or "none" if no match.
```

This is one extra LLM call (~1-2s) but can save 5-10 steps worth of time.

**Phase 2 (optimized, future):** Use Apple's `NaturalLanguage.framework` for on-device sentence embeddings. Embed each procedure's scenario once, embed the incoming task, compute cosine similarity locally. Zero API calls, sub-100ms matching. Apple's `NLEmbedding` supports sentence-level embeddings in English and other languages, built into iOS.

### Step 4: Hint injection (not blind replay)

If a match is found, inject the procedure into the system prompt as a guide, not a script:

```
<LEARNED_PROCEDURE confidence="high" uses="5/5 successful">
You've completed this type of task before. These steps worked:
1. openApp("Messages")
2. tap the contact's conversation (look for "{contact}" in the list)
3. typeAndSubmit(elementText: "Message", text: "{message}", submitKey: "send")
4. takeScreenshot to verify sent

Follow this plan unless the screen shows something unexpected.
If the UI looks different than expected, fall back to normal exploration.
</LEARNED_PROCEDURE>
```

The agent follows the procedure as a guide but still takes screenshots and adapts. This avoids the -1.3pp degradation the SoK survey found with blind self-generated replay.

### Step 5: Trust scoring and promotion

Track reliability per procedure using a simplified Bayesian approach (MACLA-inspired):

```swift
extension Procedure {
    var reliability: Double {
        guard successCount + failCount > 0 else { return 0 }
        return Double(successCount) / Double(successCount + failCount)
    }

    var trustTier: TrustTier {
        let total = successCount + failCount
        if total < 2 { return .hint }           // Tier 2: show as suggestion
        if reliability >= 0.8 { return .trusted } // Tier 4: skip some verification
        if total >= 5 && reliability < 0.5 { return .prune } // Delete
        return .hint
    }
}

enum TrustTier {
    case hint      // Inject as suggestion, full verification
    case trusted   // Skip intermediate screenshots, faster execution
    case prune     // Remove — unreliable
}
```

**Trusted procedures** allow the agent to skip intermediate `takeScreenshot` calls and go faster. For the drag-and-drop game example: after 3-4 successful rounds, the agent executes the grab-drag-release sequence without pausing to screenshot each step.

**Pruning:** When `totalUses >= 5` and `successRate < 0.5`, delete the procedure (ReMe's approach). It's hurting more than helping.

### Step 6: Procedure updates after execution

After every task that used a procedure:
- **Success:** `successCount += 1`, update `lastUsed`
- **Failure:** `failCount += 1`. If the agent deviated from the procedure and still succeeded, extract a new/updated procedure from the actual trace.

When a procedure fails but the agent completes the task via a different path, the new trace replaces the old procedure's steps (contrastive refinement from MACLA).

## File Structure (on-device)

```
Documents/
  memories/
    user.md              # Semantic memory (existing)
  logs/
    tasks.jsonl          # Task history with traces (enhanced)
  procedures/
    procedures.jsonl     # Learned procedures
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  New task arrives: "text Emiliano what school I go to"       │
└─────────────┬───────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────┐
│  MATCH: Check procedures.jsonl for matching scenario        │
│  Method: LLM classification (Phase 1) or NLEmbedding (P2)  │
│  Result: Procedure #abc matches (reliability: 100%, 5/5)    │
└─────────────┬───────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────┐
│  INJECT: Add <LEARNED_PROCEDURE> to system prompt           │
│  Trust tier: "trusted" → agent can skip some screenshots    │
└─────────────┬───────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────┐
│  EXECUTE: Normal agent loop, guided by the procedure        │
│  Each step records structured ToolTrace                     │
└─────────────┬───────────────────────────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────────────────────────┐
│  LOG: Save full trace to tasks.jsonl                        │
│  UPDATE: procedure.successCount += 1                        │
│  EXTRACT: If new task type, create new Procedure via LLM    │
└─────────────────────────────────────────────────────────────┘
```

## Shortcut Copilot (future layer)

After a procedure reaches high trust (e.g., 5+ successes, 100% reliability), the agent can offer:

> "You've texted Emiliano 5 times through me. Want me to set up an iOS Shortcut so you can do it with one tap, no agent needed?"

iOS 26 added 25+ new Shortcuts actions and Apple is building AI-powered Shortcut creation via natural language. The Shortcuts framework supports programmatic creation via App Intents. The agent could construct and propose Shortcuts using this framework — but this is a future layer that depends on the procedural memory system being built first.

## Research Contribution

**No existing mobile GUI agent implements on-device procedural memory with automatic extraction from successful task trajectories.**

- AppAgentX requires Neo4j + Pinecone (server-side infrastructure)
- Voyager operates in Minecraft, not mobile
- ReMe is domain-agnostic but uses a vector database
- Rabbit R1 requires explicit user recording, not automatic learning
- OpenClaw has no automatic procedure extraction

Our approach combines:
1. **Automatic extraction** from successful runs (not user-recorded)
2. **On-device storage** (JSONL files, no database)
3. **On-device matching** via Apple NLEmbedding (no API calls for retrieval)
4. **Hint injection** (not blind replay — avoids the SoK degradation finding)
5. **Bayesian trust scoring** (procedures earn autonomy over time)
6. **Real iOS device** (not simulator, not browser, not game)

### Relevant citations

- ReMe: arXiv:2512.10696 — scenario-based indexing, utility-based pruning
- AppAgentX: arXiv:2503.02268 — mobile agent shortcut extraction from trajectories
- Voyager: arXiv:2305.16291 — skill library with code + description + index
- MACLA: arXiv:2512.18950 — Bayesian reliability, hierarchical procedures, contrastive refinement
- SoK Agent Skills: arXiv:2602.20867 — trust tiers, curated vs self-generated skill performance
- CoALA: arXiv:2309.02427 — procedural memory taxonomy for language agents
- Memp: arXiv:2508.06433 — exploring agent procedural memory
- SEAgent: arXiv:2508.04700 — self-evolving computer use agent
