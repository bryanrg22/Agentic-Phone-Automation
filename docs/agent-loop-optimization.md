# Agent Loop Optimization: 83s to 24s

**Date:** March 31, 2026
**Task:** "Text Emiliano what school I go to" (Messages, physical iPhone 15 Pro)
**Model:** GPT-5.4 (OpenAI)

## Results

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Task completed | No (manual stop) | Yes | -- |
| Steps | 12+ | 4 | **3x fewer** |
| Total time | 83s+ | 23.9s | **3.5x faster** |
| Correct message | No | Yes | -- |
| Failed taps (stuck) | 5 | 0 | **Eliminated** |
| Wasted time | 40s+ | 0s | **Eliminated** |

4 steps is the theoretical minimum for this task (open app, tap contact, type+send, verify+complete).

---

## Six-Run Benchmark

Each run tested the same task. Failures were analyzed, fixes applied, and the next run validated them.

| | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Run 6 |
|---|-------|-------|-------|-------|-------|-------|
| **Steps** | 12+ | 6 | 9 | 5 | 6 | **4** |
| **Time** | 83s+ | 33.9s | 50.3s | 23.6s | 38.9s | **23.9s** |
| **Completed** | No | Yes | Yes | Yes | Yes | **Yes** |
| **Correct** | No | Yes | No | No | Yes | **Yes** |
| **Send retries** | 5 | 0 | 1 | 1 | 1 | **0** |
| **askUser** | 1 (15s) | 1 (5.5s) | 2 (7.5s) | 0 | 0 | **0** |
| **Key issue** | Maestro fallback + stuck | Baseline | Double HITL + AI variance | USCI bug | Screenshot timing | **Clean** |

---

## Root Causes and Fixes

### 1. Maestro CLI Fallback (Run 1: 26s wasted)

**Problem:** When `tapText` couldn't find an element in the view hierarchy, it silently spawned a full Java process (`maestro.tap(text)`) with a 60-second timeout. On physical devices, this took 20-30s and usually failed. One call consumed 31% of the entire run.

**Why it happened:** `tapText` has three tiers — CSV hierarchy search, JSON hierarchy search, Maestro CLI fallback. The first two are fast (~500ms). The third spawns a JVM:

```
tapText("Emiliano")
  → Tier 1: CSV search → NOT FOUND
  → Tier 2: JSON search → NOT FOUND
  → Tier 3: maestro.tap("Emiliano") → JVM boot (5-8s) → text scan (10-15s) → FAIL
  = 26 seconds wasted
```

**Fix:** Removed the Maestro CLI fallback entirely. `tapText` now returns `ERROR: Element not found` immediately (~0ms). The AI recovers on its own in the next step — which it was doing anyway after the 26s failure.

**Impact:** Step 4 went from 29.6s to ~3s.

### 2. Stuck Detection Evasion (Run 1: 14s wasted, 5 failed taps)

**Problem:** The AI tried to tap the send button 5 times at slightly different coordinates (88-95%, 60-62%), missing each time. Stuck detection never fired because it only checked for exact string duplicates, and the AI varied coordinates and descriptions each attempt.

```
tap({"x":88,"y":60,"description":"blue send arrow in Messages"})       ← unique
tap({"x":91,"y":62,"description":"blue send arrow inside Messages"})   ← unique
tap({"x":89,"y":61,"description":"blue send arrow in message bar"})    ← unique
```

**Fix:** Semantic stuck detection. Now catches:
- Same tool name with coordinates clustered within a 10% range
- Same `tapText` target text regardless of other arguments

**Impact:** Would have fired after the 3rd tap instead of letting 5 accumulate.

### 3. Missing UI Element Coordinates (Run 1: structural inefficiency)

**Problem:** `getUIElements` fetched the view hierarchy (which contains exact pixel positions for every element) but stripped the coordinates and only returned labels:

```
Before: - "Send"
After:  - "Send" at (90%, 56%)
```

The AI had to either call `tapText` (which fetched the hierarchy again — redundant) or guess coordinates from the screenshot (inaccurate).

**Fix:** `getUIElements` now returns coordinates alongside labels. Additionally, UI elements are auto-bundled with every screenshot via parallel `Promise.all` fetch, eliminating the need for a separate `getUIElements` call.

**Impact:** The AI uses exact hierarchy coordinates with `tap(x, y)` (~100ms) instead of `tapText` (~600ms) or visual guessing (inaccurate). Also eliminates one full AI reasoning step per action.

### 4. Screenshot Timing (Runs 4-5: AI retried actions that already succeeded)

**Problem:** After action tools on physical devices, the screenshot fired immediately (~100ms after touch). iOS animations (navigation push: 330ms, keyboard: 250ms, modals: 350ms) hadn't completed yet. The AI saw the pre-animation state and thought the action failed.

```
tap("Emiliano") → success → screenshot fires at 100ms → shows old screen
AI: "The tap didn't work, let me try again"  → unnecessary retry
```

**Fix:** Smart settle delay — 350ms wait before screenshot, but only after navigation actions (`tap`, `tapText`, `scroll`, `swipe`, `typeAndSubmit`). Non-navigation actions (`openApp`, `inputText`, `pressKey`) skip the delay.

**Impact:** Prevents false retries. The screenshot shows the settled UI state.

### 5. Hardcoded Send Button Coordinates (Runs 4-5: "USCI" bug)

**Problem:** `typeAndSubmit` with `submitKey: "send"` hardcoded the send button at (92%, 74%). On iPhone 15 Pro (393x852 points), that's pixel (362, 631). When the keyboard is open, the keyboard starts at ~y=500px. The hardcoded tap landed on the "I" key, turning "USC" into "USCI".

```
typeAndSubmit types "USC"
  → waits 300ms
  → taps (362, 631) ← KEYBOARD AREA, hits "I" key
  → text field now shows "USCI", message unsent
```

**Fix:** Replaced hardcoded coordinates with a view hierarchy lookup. The code now searches for the send button by label ("Send", "sendButton", "arrow.up.circle.fill"), extracts its actual pixel position from the frame data, and taps there. Falls back to `pressKey('enter')` if not found.

Run 6 log confirmed: `[typeAndSubmit] Send button found at (90%, 56%) — label: "Send"`

**Impact:** Correct message sent. No "USCI" bug. Works regardless of keyboard state, phone size, or orientation.

### 6. Post-Send Screenshot Timing (Run 5: AI tapped send again)

**Problem:** Even after `typeAndSubmit` successfully sent the message, the auto-capture screenshot fired before the send animation completed. The AI saw the message still in the text field and tapped send again — opening the text effects tray.

**Fix:** Two-layer settle delay:
1. 500ms internal sleep after the send tap inside `typeAndSubmit` (before the tool returns)
2. 350ms external settle delay before the auto-capture screenshot

Total 850ms gives the send animation time to complete. The screenshot shows the message as a sent bubble.

**Impact:** AI trusted the visual evidence + tool result and went straight to `taskComplete`. No extra tap.

### 7. AI Behavior Optimizations (Runs 3-4: prompt-guided)

**Double askUser (Run 3):** AI asked for confirmation twice — once for content, once for action. Fix: prompt rule "Only ask ONCE per action."

**saveMemory on its own step (Run 3):** AI used an entire step just to save memory. Fix: prompt rule "Always bundle saveMemory with another action tool."

**Ambiguous typeAndSubmit return message (Runs 4-5):** `"Typed X and pressed send"` didn't clearly confirm the message was delivered. Fix: changed to `"Message sent: X — the send button was tapped automatically. Do NOT tap send again."`

**Memory-based HITL skip (Runs 4-6):** After the user confirmed "USC" in Run 2, the memory system stored the preference. Subsequent runs loaded this memory and skipped askUser entirely. This is the episodic memory system working as designed.

---

## Architecture: How Tapping Works

The agent has three ways to tap elements, forming a reliability hierarchy:

### `tap(x, y)` — 100ms, uses provided coordinates
The AI provides percentage coordinates. Code converts to pixels and taps via direct HTTP to the XCTest runner on the device. Fast but accuracy depends on where the coordinates come from.

### `tapText("label")` — 600ms, uses hierarchy lookup
The AI provides a text label. Code fetches the view hierarchy via HTTP (~500ms), searches for the label, extracts pixel coordinates from the element's frame, taps via direct HTTP (~100ms). Accurate but slower due to the redundant hierarchy fetch.

### Auto-bundled UI elements — 0ms additional, hierarchy included with screenshot
Every auto-captured screenshot includes a parallel-fetched list of UI elements with their coordinates. The AI reads `- "Send" at (90%, 56%)` and uses `tap(90, 56)`. This combines the accuracy of hierarchy lookup with the speed of coordinate tapping.

**Before optimization:**
```
Step N: Action → screenshot
Step N+1: AI calls getUIElements → labels only, no coordinates
Step N+2: AI calls tapText("Send") → fetches hierarchy AGAIN → taps
```

**After optimization:**
```
Step N: Action → 350ms settle → screenshot + hierarchy (parallel) → AI sees both
Step N+1: AI calls tap(90, 56) using coordinates from bundled elements → taps
```

One fewer step. One fewer hierarchy fetch. 500ms faster per tap.

---

## Performance Breakdown (Run 6)

| Step | Action | AI | Tools | Screenshot | Total |
|------|--------|-----|-------|------------|-------|
| 1 | openApp + saveMemory | 1.3s | 1.4s | 3.1s | 5.8s |
| 2 | tap Emiliano (18%, 21%) | 1.7s | 0.7s | 2.1s | 4.8s |
| 3 | typeAndSubmit "USC" | 2.5s | 5.3s | 1.9s | 10.0s |
| 4 | taskComplete | 1.8s | 0.0s | 0.0s | 1.8s |
| **Total** | | **7.3s** | **7.3s** | **7.1s** | **23.9s** |

Time distribution: AI 31% | Tools 31% | Screenshots 30% | Overhead 8%

### Where time is spent
- **AI inference (7.3s):** GPT-5.4 API latency. 4 calls averaging 1.8s each. Not optimizable on our end.
- **Tool execution (7.3s):** Dominated by `typeAndSubmit` (5.3s) which types text + taps send. The typing itself takes ~2-3s on physical device.
- **Screenshots (7.1s):** Parallel fetch of screenshot + view hierarchy. Includes settle delays. First call has a cold-start penalty (~3s) as iOS builds the accessibility tree for the new app.

### Remaining optimization headroom
- Screenshot cold start (step 1): ~3s → could potentially reduce with XCTest runner keep-alive
- typeAndSubmit tool time: 5.3s → typing speed limited by XCTest character input rate
- AI inference: 7.3s → model/provider dependent, not controllable

---

## Timing Measurements

### iOS Default Animation Durations
| Animation | Duration | Source |
|-----------|----------|--------|
| Navigation push/pop | 330ms | UIKit (Chameleon reimplementation) |
| Modal present/dismiss | ~350ms | Community consensus |
| Keyboard show/hide | 250ms | UIKeyboardAnimationDurationUserInfoKey |
| CATransaction default | 250ms | Apple docs |

### Agent Settle Delay Policy
| Action Type | Settle Delay | Reason |
|-------------|-------------|--------|
| tap, tapText, scroll, swipe | 350ms | Screen transition animations |
| typeAndSubmit | 350ms + 500ms internal | Send animation + transition |
| openApp | None | App loading, not a transition |
| inputText, pressKey | None | No visual transition |

---

## Research Relevance

This optimization work demonstrates several findings relevant to mobile GUI agent research:

1. **View hierarchy as ground truth:** Using the accessibility tree for element positions is strictly more accurate than visual coordinate estimation. Auto-bundling hierarchy data with screenshots eliminates a full reasoning step.

2. **Cascading failure modes:** A single failed hierarchy lookup triggered a 26s Maestro CLI fallback, which caused a retry, which caused stuck detection to miss, leading to 40s+ of wasted time from one root cause.

3. **Screenshot timing matters:** On physical devices, the delay between action execution and UI state capture directly affects agent accuracy. Too early = false retries. The optimal delay matches iOS animation durations (250-350ms).

4. **LLM behavior is non-deterministic:** Same model, same task, different step counts (4-9 across runs). Infrastructure fixes are deterministic and reliable. Prompt-based behavior fixes are probabilistic — they influence but don't guarantee.

5. **Compound tools reduce round trips:** `typeAndSubmit` (tap + type + send in one call) eliminates 2-3 AI reasoning steps compared to separate tool calls. But the compound tool must handle internal failures gracefully and report results unambiguously.

### Related Work
- **SecAgent** (arXiv 2025): Semantic context — rolling text summaries replace stacked screenshots. We use this (single-image mode).
- **AppAgent** (Tencent, CHI 2025): Grid overlay for spatial grounding.
- **ZoomClick** (Princeton, 2025): Iterative zoom for precise small-target tapping.
- **ScreenSpot-Pro** (arXiv 2025): Screenshot compression — higher resolution hurts, not helps.
- **CoALA** (arXiv 2309.02427): Formal taxonomy of agent memory (episodic, semantic, procedural). Our memory system follows this.
