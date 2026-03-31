# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
npm run build          # Bundle with tsup → dist/index.js
npm run dev            # Run src/index.ts directly with tsx
npm run typecheck      # tsc --noEmit
npm run lint           # eslint src/
npm run lint:fix       # eslint src/ --fix
```

**Running the tool:**

```bash
# Maestro and Java must be on PATH for all commands
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"

# ─── SIMULATOR ───

# Tool-based agent (primary, recommended)
node agent.mjs "search for USC on maps" --max-steps 15 --model gemini-2.5-flash-lite

# Simple runner (screenshot → LLM → action loop, no tool calling)
node run.mjs com.apple.Maps "Search for USC" --max-steps 10

# ─── PHYSICAL iPHONE (2 terminals required) ───

# Terminal 1: Start Maestro bridge (taps, typing, screenshots — all over USB port 6001)
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin" && maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C

# Terminal 2: Run the phone agent
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin" && node agent.mjs "search for USC on maps" --phone --provider openai

# Provider flag: --provider openai (default: gemini) | Model flag: --model gpt-5.4
# Agent modes: --agent-mode baseline|single-image|vision-gated

# ─── ACTION BUTTON + DYNAMIC ISLAND (full demo setup) ───

# Terminal 1: Maestro bridge (same as above)
# Terminal 2: Frontend server (accepts voice tasks + provides /status for Dynamic Island)
lsof -ti:8000 | xargs kill -9; export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin" && node frontend/server.mjs --provider openai

# iPhone Action Button shortcut sends POST to http://Bryans-MacBook-Pro.local:8000/task
# MobileAgentCompanion app polls /status for Dynamic Island live updates
# Phone and Mac must be on the same Wi-Fi network
# Companion app: enter "Bryans-MacBook-Pro.local" in the IP field and tap Connect

# ─── FRONTEND WEB UI ───

# Start server, then open http://localhost:8000 or network IP on phone Safari
node frontend/server.mjs
```

## Architecture

The system automates mobile apps via an observe-decide-act loop: screenshot the device → send to a vision LLM → LLM returns an action (tap, type, scroll) → execute via Maestro → repeat.

### Entry points:

- **`agent.mjs`** — Tool-based agent (simulator + physical phone). AI picks which app and action to use. Has instant tools (Maps search, Google search, dark mode via `xcrun simctl` — simulator only) and interaction tools (tap, type via Maestro). Supports `--phone` flag for physical iPhone. Supports `--provider openai|gemini` and `--agent-mode baseline|single-image|vision-gated`. Has human-in-the-loop (`askUser` tool) — agent pauses and asks user via Dynamic Island when uncertain (e.g., multiple contacts match).

- **`run.mjs`** — Simple runner (simulator only). User specifies bundle ID + task. Each step: screenshot → send to LLM → parse JSON action → execute via Maestro.

- **`run-phone.mjs`** — Physical iPhone runner. Same AI loop as `run.mjs` but uses Maestro via `maestro-ios-device` bridge over USB.

- **`frontend/server.mjs`** — Server for Action Button + Dynamic Island + web UI. Accepts `POST /task` (voice tasks from Shortcut), `POST /stop` (stop agent), `POST /respond` (human-in-the-loop responses), `GET /status` (Dynamic Island polling). Spawns `agent.mjs` as child process. Supports `--provider openai|gemini`.

### Original source (`src/`):

| File | Role |
|------|------|
| `src/index.ts` | CLI entry (commander). Parses args, validates env, creates TaskExecutor |
| `src/executor.ts` | Orchestrates the observe/decide/act loop with ora spinners |
| `src/agent.ts` | Wraps Gemini (Vercel AI SDK). Builds system prompt, maintains conversation history, detects stuck patterns |
| `src/maestro.ts` | Translates actions to Maestro YAML flows. Handles simulator + physical device commands |
| `src/types.ts` | TypeScript interfaces: TaskConfig, AgentDecision, AgentParams, ExecutionResult |
| `src/utils/install-maestro.ts` | Maestro/maestro-ios-device installation helpers |

### Key data flow (agent.mjs):
```
User query → Gemini tool calling → execute tool:
  Instant tools (simctl): searchMaps, googleSearch, openURL, setAppearance, setLocation → sub-second
  Interaction tools (Maestro MCP): tap, tapText, inputText, scroll, pressKey → ~1-3s each
  Screenshot (simctl) → sent as base64 image to next LLM call
  → Loop until taskComplete or taskFailed
```

## Known Issues (this environment)

1. **`execSync` with Maestro kills the Node.js event loop on Node 23.** The Maestro Java process corrupts async operations (`setTimeout`, `fetch`, `await` stop resolving). Fix: use async `exec` callbacks or the Maestro MCP server (`maestro mcp`).

2. **`ora` spinners break terminal output.** Spinners swallow error messages and prevent output flushing. Fix: use plain `console.log` (as `run.mjs` and `agent.mjs` do).

3. **Maestro's `takeScreenshot` doesn't save PNG files** (patched JARs from maestro-ios-device broke it). Fix: use `xcrun simctl io booted screenshot` for simulator screenshots.

4. **Maestro text-based tapping is very slow (~15-20s).** `tapOn: "text"` does regex scanning across the entire view hierarchy. Fix: get view hierarchy first, find element bounds, tap by coordinates (~1.5s).

5. **The Vercel AI SDK's zod-to-JSON-schema conversion is broken** with some provider setups. `agent.mjs` uses raw `fetch` to Gemini’s OpenAI-compatible `/v1beta/openai/chat/completions` instead.

## Environment

- Node 23.9.0, Xcode 26.2, Maestro 2.1.0 (patched JARs), OpenJDK 25.0.2
- Simulator: iPhone 17 Pro, iOS 26.1 (UDID: 2757DC0C-71DC-420E-A08B-C3BA5D557DAC)
- Physical iPhone: 15 Pro (UDID: 00008130-0008249124C1401C, Team ID: C924TNC23B)
- API keys in `.env` file (`GEMINI_API_KEY`, `OPENAI_API_KEY`)

## Simulator vs Physical Device

| Capability | Simulator (`xcrun simctl`) | Physical iPhone (Maestro) |
|------------|---------------------------|--------------------------|
| Launch app | instant | ~8s (JVM startup) |
| Deep links (openURL) | instant | NOT SUPPORTED |
| Screenshots | instant (`simctl io`) | via Maestro `takeScreenshot` |
| Tap/type/scroll | via Maestro MCP (~1-3s) | via Maestro bridge (~5-8s) |
| Dark mode toggle | instant (`simctl ui`) | NOT SUPPORTED |
| Set GPS location | instant (`simctl location`) | NOT SUPPORTED |
| Clipboard | instant (`simctl pbcopy`) | NOT SUPPORTED |

**Why the difference:** `xcrun simctl` has direct system access to the simulator — it can open URLs, toggle settings, set location, etc. instantly. On a physical iPhone, Maestro can only do what a human finger can: tap, type, scroll. There are no system-level shortcuts. The AI agent handles this naturally by tapping through the UI step by step.

## Baseline

The **physical iPhone agent** (`node agent.mjs "task" --phone`) is the primary baseline for hackathon testing and demos. Requires 2 terminals: maestro bridge + agent. All improvements are layered on top of this baseline — the baseline must always work as-is.

## Agent Modes (SecAgent-inspired efficiency)

Three modes for benchmarking, controlled via `--agent-mode`:

| Mode | Behavior |
|------|----------|
| `baseline` | Original — all screenshots kept in conversation history |
| `single-image` (default) | Strip old screenshots + rolling text summary (SecAgent paper) |
| `vision-gated` | Hash-based — skip screenshots when UI hierarchy hasn't changed |

Vision-gated uses `getUIElements` to hash the screen state after each action. If the hash is unchanged, no screenshot is needed. Forces screenshot when: step 1, hash changed, hierarchy empty, stuck, error, or every K steps (`--vision-every-k`, default 5).

## iOS Companion App (Dynamic Island)

`ios/MobileAgentCompanion/` — SwiftUI app that shows agent progress in the Dynamic Island.

- Polls `GET /status` every 500ms
- Live Activity shows: phase icon, task name, current thought, progress bar, elapsed time, step count
- **Stop button** (expanded view) — sends `POST /stop` via `StopAgentIntent`
- **Human-in-the-loop** — when agent calls `askUser`, Dynamic Island shows question + option buttons with yellow keyline tint. User taps a choice, `RespondToAgentIntent` sends it to `POST /respond`, agent continues
- Completion state shows green checkmark for 4 seconds before dismissing

## Memory Architecture

Two memory types following the CoALA taxonomy (arXiv:2309.02427):

**Semantic memory** (`memories/user.md`) — user facts, preferences, resolved ambiguities. Loaded into system prompt at startup (always available). Agent writes via `saveMemory` tool when it learns something new. Same approach as ChatGPT (bio tool + system prompt injection), Claude Code (CLAUDE.md), and OpenClaw (340k GitHub stars, uses MEMORY.md). The paper "Beyond the Context Window" (arXiv:2603.04814) validated that injection has higher accuracy than retrieval for compact memory.

**Episodic memory** (`logs/tasks.jsonl`) — task history in append-only JSONL format. Each entry: timestamp, task, steps, time, success/fail, mode, model. Same format as OpenClaw's session logging. Agent reads via `recallHistory` tool. The position paper "Episodic Memory is the Missing Piece" (arXiv:2502.06975) argues this is critical for agents that learn from operational history.

**Why JSONL + markdown (not a database):** For a personal agent with dozens of facts and hundreds of task logs, file-based storage is optimal — zero dependencies, crash-safe (append-only), human-readable, git-trackable. OpenClaw uses the same pattern at 340k stars. Architecture supports future migration to SQLite or vector search when memory grows large.

**Key research papers:**
- MemGPT (Berkeley, arXiv:2310.08560) — tiered memory: working memory (always in prompt) + long-term storage (retrieved on demand)
- Beyond the Context Window (arXiv:2603.04814) — injection beats retrieval for compact memory; hybrid wins overall
- Memory for Autonomous LLM Agents (arXiv:2603.07670) — comprehensive survey, validates hierarchical virtual context
- Generative Agents (Stanford, arXiv:2304.03442) — memory stream with recency + relevance + importance scoring
- CoALA (arXiv:2309.02427) — formal taxonomy: episodic, semantic, procedural memory for language agents

## Key Design Decisions

- **Coordinates are percentages (0-100)**, not pixels. Survives different device sizes.
- **Action history** is passed to the AI each step for stuck detection and context.
- **Conversation history** is windowed to last 8 messages to manage token budget.
- **Instant tools use `xcrun simctl`** (sub-second, simulator only) while interaction tools use **Maestro** (tap/type/scroll, works on both).
- **View hierarchy** (`inspect_view_hierarchy` via MCP) provides exact element accessibility text, which is more reliable than coordinate guessing from screenshots.
- **Physical device requires `maestro-ios-device` bridge** running in a separate terminal over USB. The bridge boots once, then all commands go through it.
