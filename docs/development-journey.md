# Development Journey

A chronological account of every feature, fix, and research decision made during development. This document explains not just what was built, but why — with links to research papers and industry precedents.

---

## Phase 1: SecAgent-Inspired Efficiency

### Problem
The original agent sent **every screenshot** in the conversation history to the LLM. A 10-step task could have 6-8 full PNG images stacked in the messages array — massive token cost and latency.

### Research
- Read the **SecAgent paper** (arXiv:2603.08533) which proposed replacing visual history with text summaries
- Discovered the paper does NOT have a "vision gate" — their contribution is semantic context (text summaries replacing old screenshots). The vision gate is our extension.
- Read the **AppAgent paper** (arXiv:2312.13771) which confirmed our screenshot→LLM→action loop matches the industry baseline

### What we built

**1. Single-image mode (`--agent-mode single-image`)**
- Strip all old screenshots from conversation history before each LLM call
- Only the latest screenshot is sent as an image
- Old screenshots replaced with text: `[Previous screenshot | Context: Step 3: tapText(Settings)] Here is the current screen.`
- This is the default mode

**2. Rolling text summary**
- After each step, build a one-line summary from tool calls: `Step 3: tapText(Settings), takeScreenshot`
- Injected as a `[Context]` message so the LLM knows what happened on prior steps
- Zero extra API calls — summaries built from existing tool results

**3. Vision-gated mode (`--agent-mode vision-gated`)**
- After every action, auto-fetch the UI hierarchy and hash the accessibility labels
- If hash unchanged → screen didn't change → skip screenshot, text-only step
- If hash changed → new screen → allow screenshot
- If hierarchy empty → force screenshot (blind otherwise)
- Safety fallback every K steps (`--vision-every-k`, default 5)
- Plus overrides: step 1, stuck detection, errors, taskComplete

**4. Benchmarking flags**
- `--agent-mode baseline|single-image|vision-gated` — three modes for A/B comparison
- Per-step logging tags each step as VISION or GATED
- Completion summary shows vision calls vs gated calls and vision rate %

### Key finding from the paper
SecAgent showed N=1 image + text summary = same accuracy as N=5 images, at **38% fewer tokens** and **50% less latency**. Our single-image mode implements exactly this.

---

## Phase 2: Physical iPhone Setup

### Problem
The `viewHierarchy()` method for physical phones was hardcoded to return empty — someone assumed it wouldn't work.

### What we discovered
Ran `maestro hierarchy` through the Maestro bridge on a physical iPhone 15 Pro:
- **Camera app**: mostly empty labels (viewfinder has no accessibility data)
- **Settings app**: rich data — "Settings", "Wi-Fi", "Bluetooth", "Cellular", all menu items with bounds

The hierarchy DOES work on physical iPhone through the bridge. The stub was wrong.

### What we fixed
- Replaced the empty stub with actual `maestro hierarchy` call through port 6001
- Fixed the `getUIElements` parser to handle both MCP format (`accessibilityText=value`) and JSON format (`"accessibilityText" : "value"`) since physical phones return JSON
- Confirmed `getUIElements` now returns real labels on physical devices

---

## Phase 3: Action Button Voice Trigger

### Problem
Running the agent required typing commands in the terminal. Not a "personal AI" experience.

### Solution
Created an Apple Shortcut with two actions:
1. **Dictate Text** (Stop Listening: After Pause)
2. **Get Contents of URL** → POST to `http://Bryans-MacBook-Pro.local:8000/task` with JSON body `{ "task": "<dictated text>" }`

Assigned to the iPhone Action Button. Works on any shared Wi-Fi network using Bonjour `.local` hostname (no IP address needed).

### Server changes
- Added `POST /task` endpoint to `frontend/server.mjs`
- Server spawns `agent.mjs --phone` as a child process
- Agent output printed to server terminal + broadcast to WebSocket clients
- Added `--provider openai|gemini` flag to server

---

## Phase 4: Dynamic Island (Live Activity)

### Problems encountered and solutions

**Build errors — Live Activities disabled in compiled app**
- `NSSupportsLiveActivities` was set to `NO` in Xcode build settings (`project.pbxproj`), overriding the `Info.plist` value of `true`
- Fix: changed build settings to `YES` in both Debug and Release configurations
- Root cause: Xcode's `INFOPLIST_KEY_*` build settings override manual Info.plist when `GENERATE_INFOPLIST_FILE = YES`

**ActivityKit API changes in Xcode 26**
- `Activity.request()` still throws (needs `try`)
- `activity.update()` and `activity.end()` no longer throw (don't need `try`)
- `staleDate: nil` needs explicit type: `nil as Date?`
- `pushType: .none` instead of `pushType: nil`

**Dynamic Island disappears immediately on completion**
- Discovered this is **by design** — `.after(.now + 8)` dismissal policy only keeps the **Lock Screen banner** visible, not the Dynamic Island
- Fix: call `activity.update()` with the final "complete" state FIRST (keeps Dynamic Island alive), wait 4 seconds, then call `activity.end()`
- Added `isEnding` flag to prevent polling from calling `endLiveActivity` again during the 4-second linger

**Design iterations**
- v1: Default layout — brain icon, stacked 4/25 step count, truncated task name. Looked terrible.
- v2: Redesigned — brain icon (leading), task name (center), stop button + time (trailing), thought + progress (bottom). Much cleaner.
- v3: Moved current thought to center (live action display), task name to bottom (stable reference). Stop button changed from full-width red banner to circular stop icon matching Apple's screen recording style.
- Final: Yellow `keylineTint` when waiting for user input. Slim option buttons for HITL questions.

**Stop button implementation**
- Used `Button(intent: StopAgentIntent())` — `LiveActivityIntent` runs in-process without foregrounding the app (iOS 17+)
- `StopAgentIntent` sends `POST /stop` to server and ends all Live Activities
- Added `POST /stop` endpoint to server that kills the agent process

### Research
- Apple HIG: "get to the essence of your activity, not showing too little or too much"
- Dynamic Island max expanded height: ~160pt (hard system limit, no workaround)
- `keylineTint()` is the only way to color the pill border — static color only, no animations
- Auto-expand only possible with push notification updates, not local ActivityKit updates

---

## Phase 5: Human-in-the-Loop

### Problem
The agent would guess when uncertain (e.g., multiple contacts named Kenny). For consequential actions (sending messages, making calls), it should ask the user.

### Research
- No existing mobile AI agent has shipped HITL via Dynamic Island
- Claude Agent SDK has `canUseTool` callback — the closest pattern
- Anthropic's guidance: "require human confirmation for actions with meaningful real-world consequences"
- Production consensus: use reversibility + blast radius as the decision criteria

### Implementation
- `askUser` tool — LLM calls it with a question + options array
- Agent prints `__ASK_USER__:` signal to stdout → server parses it → updates `agentState`
- Dynamic Island shows question + blue option buttons in expanded view
- `RespondToAgentIntent` sends choice to `POST /respond` → server writes to temp file → agent polls and picks up response
- File-based communication because agent runs as child process (no shared memory)

### Prompt rules
- MUST ask before: sending messages/emails/calls, deleting data, purchases, multiple matches
- NEVER ask for: tapping, scrolling, typing, opening apps
- Exception: skip `askUser` if memory already has the answer

---

## Phase 6: Persistent Memory

### Research
- **ChatGPT**: stores facts via hidden `bio` tool, injects ALL into system prompt every conversation. No search, no retrieval. Works because memory is small.
- **Claude Code**: CLAUDE.md + memory files in `~/.claude/projects/`. Loaded at session start.
- **OpenClaw** (340k GitHub stars): `MEMORY.md` for durable facts, `memory/YYYY-MM-DD.md` for daily context. SQLite + embeddings for retrieval when memory grows.
- **MemGPT** (Berkeley, arXiv:2310.08560): tiered memory — core (always loaded), recall (conversation log), archival (vector-searched).
- **"Beyond the Context Window"** (arXiv:2603.04814): injection beats retrieval for compact memory. Hybrid wins overall.

### Why we chose system-prompt injection
For a personal agent with dozens of facts, injection is optimal:
- Zero retrieval latency
- 100% recall accuracy
- Same pattern as ChatGPT, Claude Code, and OpenClaw
- Architecture supports scaling to SQLite/vector search when memory grows

### Implementation
- `memories/user.md` — markdown file with timestamped facts
- Loaded into `<USER_MEMORY>` block in system prompt at startup
- `saveMemory` tool — LLM saves new facts (deferred to after task completion)
- `recallMemory` tool — backup for reading memory on demand
- Integration with HITL: after `askUser` resolves ambiguity, agent saves the result so it never asks again

---

## Phase 7: Task History (Episodic Memory)

### Research
- **CoALA taxonomy** (arXiv:2309.02427): three memory types — episodic, semantic, procedural. We had semantic (user facts) and procedural (system prompt). Episodic was missing.
- **"Episodic Memory is the Missing Piece"** (arXiv:2502.06975): argues agents must have episodic memory to learn from operational history.
- **OpenClaw**: append-only JSONL session logs, same format we adopted.

### Implementation
- `logs/tasks.jsonl` — one JSON line per completed/failed task
- Fields: timestamp, task, summary, steps, time, success, mode, grounding, model, provider
- `recallHistory` tool — returns last 10 tasks as readable text
- Automatic logging — writes on `taskComplete` or `taskFailed`, no tool call needed

---

## Phase 8: Step Reduction Optimizations

### Waste analysis
Tested "Text Bryan hello" — took 12 steps, 36.8 seconds. Analysis showed:
- 5 steps were just `takeScreenshot` calls that should have been automatic
- 1 step was `saveMemory` mid-task (could be deferred)
- 1 step was `copyToClipboard` which doesn't work on physical phone
- Total waste: ~6 steps

### Fixes implemented
1. **Auto-capture** — screenshots automatically taken after action tools (openApp, tap, tapText, inputText, pressKey, scroll, swipe). LLM no longer wastes a step calling takeScreenshot.
2. **`typeAndSubmit` compound tool** — tap field + type + press enter in one call. Special handling for Messages blue send arrow.
3. **Deferred `saveMemory`** — facts queued during task, written to disk after completion.
4. **Hidden `copyToClipboard` on physical phone** — tool removed from LLM's toolset when `--phone`.
5. **Stronger chaining prompt** — "ALWAYS chain multiple tool calls" instead of "where possible".

### Expected impact
12 steps → ~6-7 steps for the same task (~40% reduction).

---

## Phase 9: System Prompt Restructure

### Research
- Studied Anthropic's Claude Computer Use system prompt — uses XML-tagged sections (`<SYSTEM_CAPABILITY>`, `<IMPORTANT>`)
- Their approach: describe exact environment, include app-specific workarounds, enforce self-verification
- Claude in Chrome extension — uses Chrome DevTools Protocol for browser control, same observe-decide-act loop as our agent

### Changes
- Restructured with XML tags: `<SYSTEM_CAPABILITY>`, `<AVAILABLE_APPS>`, `<USER_MEMORY>`, `<STRATEGY>`, `<IMPORTANT>`, `<RULES>`, `<VISION_GATE>`
- Added iOS-specific context: "iPhone 15 Pro running iOS 26 (Liquid Glass design)"
- App-specific workarounds in `<IMPORTANT>`: Messages send button coordinates, Maps search bar position, Photos grid layout
- Self-verification: "After EVERY action, take a screenshot to verify it worked"
- Tool chaining: "ALWAYS chain multiple tool calls in a single response"
- Dynamic date injection

---

## Phase 10: Context Awareness

### Discovery
The agent can already handle "search for this" while looking at any content — homework, lectures, articles. No code change needed. The LLM's vision capability interprets whatever is on screen from the screenshot and acts on it.

### How it works
1. User says "search for this" while looking at a lecture slide
2. Agent takes screenshot → LLM sees the content via vision
3. LLM extracts the relevant topic from the screenshot
4. Agent opens Safari and searches for it

Zero implementation cost — just the existing tools used with a vague, context-dependent prompt.

---

## Grounding Strategies (implemented, testing pending)

Three independent strategies for improving tap accuracy:

| Strategy | How it works | Best for |
|----------|-------------|----------|
| `baseline` | Raw screenshot, LLM guesses | Simple/large targets |
| `grid` | Yellow grid lines at every 10% overlaid on screenshot | General coordinate accuracy |
| `zoomclick` | Zoom into rough area, get precise coordinates from zoomed view | Small buttons, dense UI |

These combine with agent modes: `--agent-mode X --grounding Y` gives 9 possible configurations for benchmarking.

---

## Research Papers Referenced

| Paper | arXiv | Role |
|-------|-------|------|
| SecAgent | 2603.08533 | Efficiency: semantic context replaces visual history |
| AppAgent | 2312.13771 | Baseline: multimodal phone control pipeline |
| MemGPT | 2310.08560 | Memory: tiered architecture (core/recall/archival) |
| CoALA | 2309.02427 | Taxonomy: episodic/semantic/procedural memory |
| Beyond the Context Window | 2603.04814 | Memory: injection beats retrieval for compact memory |
| Generative Agents | 2304.03442 | Memory: stream architecture with recency/relevance/importance |
| Memory for Autonomous LLM Agents | 2603.07670 | Survey: validates hierarchical virtual context |
| Episodic Memory is the Missing Piece | 2502.06975 | Position: agents need episodic memory to learn |

## Industry Precedents

| System | What we borrowed |
|--------|-----------------|
| ChatGPT | Memory via system-prompt injection (bio tool) |
| Claude Code | CLAUDE.md memory files, XML-structured prompts |
| Claude Computer Use | Single-loop architecture, screenshot processing, `<SYSTEM_CAPABILITY>` prompt pattern |
| Claude in Chrome | Browser control via DevTools Protocol (analogous to our Maestro bridge) |
| OpenClaw (340k stars) | JSONL session logging, markdown memory files, hybrid injection + retrieval |
| Apple Screen Recording | Dynamic Island stop button design (circular red icon) |
