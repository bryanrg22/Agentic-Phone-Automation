# Screen Understanding: CoAT Reasoning + Unchanged Screen Detection

**Date:** March 31, 2026

## The Problem

The agent fails on unfamiliar apps because it acts before understanding. When encountering LinkedIn's Pinpoint game, it saw labeled rows ("CLUE 2", "CLUE 3") and repeatedly tapped them — 6+ steps of tapping static elements that never changed. The correct interaction was typing a guess into a text field.

The on-screen instructions were clear and sufficient:
- "All 5 clues belong to a common category. Guess the category in as few clue reveals as possible."
- A text field: "Guess the category..."
- A button: "guess"
- A counter: "1 of 5"

The AI skipped all of this and defaulted to pattern matching: "list of items → tap items."

```
Step 2: tap(15%, 54%) "Reveal first clue"     ← tapping static label
Step 3: tap(50%, 23%) "Reveal clue 2"         ← tapping static label
Step 4: tap(50%, 28%) "Reveal clue 3"         ← tapping static label
Step 5: tap(15%, 54%) "Open first clue"       ← SAME as step 2
Step 6: tap(50%, 23%) "Open clue 2 text"      ← SAME as step 3
```

51 elements every step. Screen never changed. Stuck detection didn't fire because coordinates varied too widely (15%→50% exceeds the 10% cluster threshold).

---

## Solution: Three Layers

### Layer 1: CoAT-Style Screen Reasoning (Prompt)

Inspired by **Chain-of-Action-Thought (CoAT)** from EMNLP 2024 (arXiv:2403.02713), the system prompt now requires the AI to reason through four steps before every action on a new or changed screen:

```
SCREEN UNDERSTANDING (do this BEFORE every action on a new or changed screen):
  1. Describe what app/screen you see
  2. Read ALL visible text — especially instructions, labels, and placeholders
  3. Identify interactive elements — text fields, buttons, toggles — from the UI elements list
  4. Determine the correct interaction: should you tap, type, scroll, or something else?
Only THEN choose your action.
```

**How this fixes Pinpoint:**

Without CoAT:
```
AI sees: CLUE 2, CLUE 3, CLUE 4 → "list of items → tap"
```

With CoAT:
```
1. Screen: "LinkedIn Pinpoint game screen"
2. Text: "All 5 clues belong to a common category. Guess the category..."
3. Interactive: text field "Guess the category..." at (50%, 83%), button "guess" at (90%, 83%)
4. Interaction: "I should TYPE a guess in the text field, not tap the clue labels"
```

**Research backing:** The paper "Does Chain-of-Thought Reasoning Help Mobile GUI Agents?" (arXiv:2503.16788) found that **structured output format matters more than raw reasoning capability**. Forcing the AI to describe the screen before acting is more effective than hoping it reasons better on its own.

### Layer 2: Unchanged Screen Detection (Code)

If the auto-bundled UI element count is identical for 3 consecutive steps, a warning is injected:

```
WARNING: The screen has NOT changed after 3 actions — your taps are having no effect.
You may not understand how this app works. STOP tapping and try:
1) Read ALL text on screen for instructions
2) Use webSearch to look up how this app/game works
3) Look for text fields or buttons you may have missed
```

**Implementation:**

```javascript
// Track element count across steps
let prevAutoUICount = -1;
let unchangedScreenCount = 0;

// After each screenshot + hierarchy fetch
const currentAutoUICount = (uiElementsText.match(/^- "/gm) || []).length;
if (currentAutoUICount > 0 && currentAutoUICount === prevAutoUICount) {
  unchangedScreenCount++;
  if (unchangedScreenCount >= 3) {
    // Inject warning suggesting webSearch
    unchangedScreenCount = 0; // Reset after warning
  }
} else {
  unchangedScreenCount = 0;
}
prevAutoUICount = currentAutoUICount;
```

**Why element count, not exact element comparison:** Element count is a simple, fast proxy. If the count is identical after 3 actions, the screen almost certainly hasn't changed. A more precise comparison (hashing all element labels) is possible but adds complexity for minimal benefit.

**How this catches Pinpoint:** The Pinpoint run showed 51 elements on every single step. After step 4 (3 unchanged steps), the warning would fire, directly suggesting `webSearch("how to play LinkedIn Pinpoint")`.

### Layer 3: Web Search Tool (Brave Search API)

Available as `webSearch` tool. The AI can call it:
- **Proactively** — when it recognizes an unfamiliar app from the CoAT reasoning step
- **Reactively** — when the unchanged screen warning suggests it

See `docs/web-search-tool.md` for full API details.

---

## How Other Agents Handle This

| Agent | Approach | Limitation |
|-------|----------|------------|
| **Claude Computer Use** | Post-action verification: "take a screenshot and evaluate if you achieved the right outcome." | Catches errors after they happen, doesn't prevent them |
| **OpenAI Operator (CUA)** | Perception-reasoning-action loop with learned reasoning via RL | Planning is learned behavior, not applicable to API-based models |
| **CoAT** (EMNLP 2024) | Structured 4-step reasoning: screen description → action think → next action → predicted outcome | We adapted this for our system prompt |
| **PAL-UI** (arXiv:2510.00413) | Dual-level summarization + retrieval of past screenshots | Addresses memory, not screen understanding |
| **Smol2Operator** (HuggingFace) | Two-phase training: element localization → agentic reasoning | Requires model fine-tuning |

**Key insight from Claude Computer Use docs:** Anthropic recommends adding to prompts: *"After each step, take a screenshot and carefully evaluate if you have achieved the right outcome. Explicitly show your thinking."* Our CoAT reasoning does this proactively — before the action, not after.

**Key insight from OpenAI CUA:** Operator uses reinforcement learning to teach planning. Since we use API-based models (GPT-5.4, Gemini), we can't fine-tune for planning. Structured prompting (CoAT) is the closest alternative for API-based agents.

---

## Comparison: What Each Layer Catches

| Scenario | Layer 1 (CoAT) | Layer 2 (Unchanged) | Layer 3 (Search) |
|----------|----------------|---------------------|------------------|
| Pinpoint: tapping clues instead of typing | Should catch (text field visible) | Catches after 3 steps | Provides game instructions |
| Unfamiliar game with no on-screen instructions | May not help | Catches after 3 steps | Provides game instructions |
| Coordinate miss (Messages send button) | Not relevant | Won't fire (screen changes on miss) | Not relevant |
| App loads slowly | Not relevant | May false-positive | Not relevant |

The layers are complementary:
- **CoAT** prevents the problem (read before act)
- **Unchanged detection** catches it if CoAT fails (3-step safety net)
- **Web search** resolves it (external knowledge)

---

## Research Relevance

### Novel contribution

No existing mobile GUI agent combines all three:
1. Structured screen reasoning before action (CoAT-style)
2. Behavioral detection of agent confusion (unchanged screen)
3. Real-time web search for unfamiliar app interactions

### Key papers

| Paper | Venue | Relevance |
|-------|-------|-----------|
| **CoAT: Android in the Zoo** | EMNLP 2024 | Source of structured reasoning approach |
| **Does CoT Help Mobile GUI Agents?** | arXiv 2503.16788 | Structured format > raw reasoning capability |
| **MobileRAG** | arXiv 2509.03891 | Closest work — RAG for mobile agents, but factual retrieval not UI understanding |
| **Adaptive-RAG** | NAACL 2024 | When to retrieve: complexity-based routing |
| **AppAgent v2** | arXiv 2408.11824 | Pre-exploration knowledge base, can't handle unseen apps |
| **Anthropic Computer Use** | Docs | Post-action verification best practice |
| **GUI Agent Survey** | arXiv 2504.19838 | Comprehensive survey of LLM-powered GUI agents |
