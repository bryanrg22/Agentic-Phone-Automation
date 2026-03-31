# Changelog — Optimizations & Features

Every change documented with what it does, why, and measurable impact.

## Efficiency Optimizations

### 1. Single-image mode (strip old screenshots)
- **What:** Only keep the latest screenshot in conversation history, replace old ones with text summaries
- **Why:** SecAgent paper (arXiv:2603.08533) showed N=1 image + text summary = same accuracy as N=5 images at 38% fewer tokens
- **Impact:** Reduces token usage per LLM call significantly. No accuracy loss.
- **Flag:** `--agent-mode single-image` (default)

### 2. Rolling text summary
- **What:** After each step, build a one-line summary of tool calls. Injected as context so the LLM knows what happened on prior steps without needing old screenshots.
- **Why:** SecAgent's core mechanism — text context replaces visual history
- **Impact:** Maintains context across steps without image tokens

### 3. Vision gate (hash-based)
- **What:** After each action, fetch UI hierarchy, hash the labels. If hash unchanged, skip screenshot. Only allow vision when screen actually changed, on step 1, stuck, error, or every K steps.
- **Why:** Extension of SecAgent — if the screen didn't change, no need to look at it
- **Flag:** `--agent-mode vision-gated`, `--vision-every-k N`
- **Impact:** Reduces total vision calls. Hash comparison is free.

### 4. Physical phone view hierarchy fix
- **What:** `getUIElements` was returning empty on physical iPhone. Fixed to use Maestro bridge (`maestro hierarchy` via port 6001). Also fixed the parser to handle both MCP format and JSON format.
- **Why:** View hierarchy works on physical iPhone through the Maestro bridge — the empty stub was never tested.
- **Impact:** `getUIElements` now returns real UI labels on physical phone. Enables vision-gated mode on physical device.

### 5. Auto-capture after action tools (PENDING)
- **What:** Automatically take a screenshot after every action tool (openApp, tap, tapText, inputText, pressKey, scroll, swipe) and attach it to the response. LLM no longer needs to waste a step calling takeScreenshot.
- **Why:** Waste analysis showed ~5 of 12 steps were just takeScreenshot calls that should have been automatic.
- **Expected impact:** Cut steps per task by ~40% (12 steps → ~7)

### 6. Compound typeAndSubmit tool (PENDING)
- **What:** New tool that taps a text field, types text, and presses enter — all in one tool call.
- **Why:** Currently takes 3 LLM round trips (tap field → type → press enter). Each round trip is ~1-2s of AI thinking time.
- **Expected impact:** Saves 2 steps + ~3-4s per text input action

### 7. Defer saveMemory to post-completion (PENDING)
- **What:** Instead of saving memory mid-task (costs a round trip), defer to after taskComplete.
- **Why:** saveMemory mid-task wastes a step. The fact is already in the LLM's context — it only needs to persist after the task succeeds.
- **Expected impact:** Saves 1 step per task that involves memory

### 8. Remove copyToClipboard on physical phone (PENDING)
- **What:** Hide the copyToClipboard tool when running with --phone flag.
- **Why:** Doesn't work on physical devices, but LLM still tries it, wasting a step.
- **Expected impact:** Prevents 1 wasted step in tasks that involve text

## System Prompt Improvements

### 9. XML-structured prompt (Anthropic pattern)
- **What:** Restructured system prompt with `<SYSTEM_CAPABILITY>`, `<IMPORTANT>`, `<RULES>`, `<STRATEGY>` XML tags
- **Why:** Matches Anthropic's Claude Computer Use prompt structure. XML tags help the LLM parse sections clearly.
- **Impact:** Better prompt comprehension, clearer separation of instructions vs hints vs rules

### 10. iOS-specific context
- **What:** Added iPhone 15 Pro, iOS 26, Liquid Glass design to system prompt. Added app-specific hints (Messages send button coordinates, Maps search bar position, Photos grid layout).
- **Why:** LLM didn't know it was on iOS. Knowing the platform helps with coordinate estimation and UI pattern recognition.
- **Impact:** Better coordinate accuracy for iOS-specific UI elements

### 11. Tool chaining instruction
- **What:** Added "chain multiple tool calls in a single response for efficiency" to system prompt
- **Why:** LLM was doing one tool per step when it could batch independent tools together
- **Impact:** Fewer round trips when tools are independent

## Personal AI Features

### 12. Action Button voice trigger
- **What:** iPhone Action Button → Shortcuts app → Dictate Text → POST to server → agent runs on physical phone
- **Why:** "Hey, do this for me" is the most natural personal AI interaction
- **Setup:** Shortcut sends to `http://Bryans-MacBook-Pro.local:8000/task`

### 13. Dynamic Island (Live Activity)
- **What:** MobileAgentCompanion iOS app polls `/status`, shows Live Activity with phase icon, task name, current thought, progress bar, stop button
- **Why:** Real-time progress on your actual phone — feels native, not like a dev tool
- **Features:** Stop button (StopAgentIntent), yellow keyline tint for questions, green checkmark on completion (4s linger via update-before-end pattern)

### 14. Human-in-the-loop (askUser tool)
- **What:** Agent pauses and asks user via Dynamic Island when uncertain. Option buttons in expanded view. RespondToAgentIntent sends choice back to server.
- **Why:** "Which Kenny?" — agent shouldn't guess on consequential actions. First mobile AI agent with Dynamic Island HITL (no prior implementations found).
- **Rules:** Must ask before sending messages/emails/calls, deleting data, purchases, or when multiple matches. Skip if memory already has the answer.

### 15. Persistent memory (saveMemory/recallMemory)
- **What:** `memories/user.md` stores user facts. Loaded into system prompt at startup. Agent saves new facts via saveMemory tool.
- **Why:** Same pattern as ChatGPT (bio tool), Claude Code (CLAUDE.md), OpenClaw (MEMORY.md, 340k stars). Validated by MemGPT (arXiv:2310.08560).
- **Format:** Markdown file, system-prompt injection. Scales to retrieval (SQLite/vector search) when memory grows.

### 16. Task history logging (episodic memory)
- **What:** Every completed/failed task logged to `logs/tasks.jsonl`. Agent can recall via recallHistory tool.
- **Why:** CoALA taxonomy (arXiv:2309.02427) identifies episodic memory as essential for language agents. Same JSONL format as OpenClaw.
- **Format:** Append-only JSONL — crash-safe, human-readable, zero dependencies.

### 17. Context-aware actions
- **What:** Say "search for this" while looking at anything — agent screenshots current screen, interprets content via vision, searches for it.
- **Why:** No code change needed — the LLM's vision capability handles context interpretation naturally. Just works.
- **Impact:** Powerful demo capability with zero implementation cost.
