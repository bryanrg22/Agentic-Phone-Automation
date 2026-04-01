# Web Search Tool: Why and How

**Date:** March 31, 2026

## The Problem

The agent fails on unfamiliar apps because it acts before understanding. When encountering LinkedIn's Pinpoint game, it saw labeled rows ("CLUE 2", "CLUE 3") and repeatedly tapped them — 6+ steps of tapping static elements that never changed. The actual interaction required typing a guess into a text field and pressing "guess."

The on-screen instructions were clear: "All 5 clues belong to a common category. Guess the category in as few clue reveals as possible." But the AI skipped reading them and defaulted to its trained pattern: "list of items → tap items."

```
Step 2: tap(15%, 54%) "Reveal first clue"     ← tapping static label
Step 3: tap(50%, 23%) "Reveal clue 2"         ← tapping static label
Step 4: tap(50%, 28%) "Reveal clue 3"         ← tapping static label
Step 5: tap(15%, 54%) "Open first clue"       ← SAME as step 2, loop begins
Step 6: tap(50%, 23%) "Open clue 2 text"      ← SAME as step 3
```

Screen never changed (51 elements every step). Stuck detection didn't fire because coordinates varied too widely.

## Proven Result: Pinpoint Solved in 23.4s

After implementing the three-layer solution, the agent solved LinkedIn Pinpoint correctly:

```
Step 1: openApp("LinkedIn")                                              → 3.1s
Step 2: webSearch("LinkedIn Pinpoint clue Panel category")               → 4.6s
        → Found answer: "Types of interviews" (Panel, Behavioral, etc.)
        → Read API results inline — did NOT open Safari
Step 3: inputText("Types of interviews")                                 → 7.0s
Step 4: tap(89%, 91%) "Submit guess"                                     → 4.5s
Step 5: taskComplete                                                     → 2.3s
                                                               Total:    23.4s
```

| Metric | Before (no web search) | After |
|--------|----------------------|-------|
| Steps | 6+ (looping, stopped) | 5 (completed) |
| Behavior | Tapped clue labels endlessly | Searched, typed guess, submitted |
| Screen changed? | No (51 elements every step) | Yes (52 → 19 after submit) |
| Result | Never completed | Solved correctly |

The web search call took 0.6s and returned the full answer + game mechanics. One API call replaced infinite looping.

---

## Three-Layer Solution

### Layer 1: Prompt Engineering (free, immediate)

Added to system prompt RULES:
```
UNFAMILIAR APPS: When you encounter an app or game you don't fully understand, 
STOP and read ALL visible text on screen first — look for instructions, text fields, 
and buttons. If the interaction model is still unclear, use webSearch to look up how 
the app works before acting. Do NOT blindly tap UI elements.
```

This addresses the root behavior: the AI should read before acting. The auto-bundled UI elements already show the text field (`"Guess the category..." at (50%, 83%)`) and the button (`"guess" at (90%, 83%)`), which should be sufficient for the AI to understand the interaction.

### Layer 2: Web Search Tool (Brave Search API)

For cases where on-screen instructions are insufficient, ambiguous, or absent, the agent can search the web.

**Implementation:** `webSearch` tool calling Brave Search API.

```javascript
// Tool definition
{ 
  name: 'webSearch', 
  description: 'Search the web for information. Use when you encounter an unfamiliar 
    app, game, or interface and need to understand how it works before interacting.' 
}

// Execution
const res = await fetch('https://api.search.brave.com/res/v1/web/search?q=...', {
  headers: { 'X-Subscription-Token': process.env.BRAVE_API_KEY }
});
```

**API:** Brave Search (`https://api.search.brave.com/res/v1/web/search`)
- Auth: `X-Subscription-Token` header with API key
- Returns: top 5 results with title, URL, description
- Rate: 2,000 queries/month on free tier, 1 query/second
- Key: stored as `BRAVE_API_KEY` in `.env`

**Example usage:**
```
AI encounters Pinpoint game → doesn't understand interaction
AI calls: webSearch("how to play LinkedIn Pinpoint game")
Results explain: type a category guess, fewer clues = better score
AI now knows to use the text field, not tap clues
```

## Why Brave Search

- Simple API: single GET endpoint, one header, JSON response
- Already used by Claude (Anthropic's own web search backend)
- Free tier sufficient for development/testing (2,000 queries/month)
- No SDK needed — plain `fetch`

## Three-Layer Solution (Final)

### Layer 1: CoAT-Style Screen Understanding (prompt, free)

Inspired by **Chain-of-Action-Thought (CoAT)** from EMNLP 2024, the system prompt now requires the AI to reason through four steps before every action on a new screen:

1. **Screen Description**: What app/screen is this?
2. **Read ALL text**: Instructions, labels, placeholders
3. **Identify interactive elements**: Text fields, buttons, toggles from the UI elements list
4. **Determine correct interaction**: Should I tap, type, scroll, or something else?

This directly addresses the Pinpoint failure — the AI would be forced to describe the text field and "guess" button before acting.

### Layer 2: Unchanged Screen Detection (automatic trigger)

If the auto-bundled UI element count is identical for 3 consecutive steps, the agent injects:

```
WARNING: The screen has NOT changed after 3 actions — your taps are having no effect. 
You may not understand how this app works. STOP tapping and try:
1) Read ALL text on screen for instructions
2) Use webSearch to look up how this app/game works
3) Look for text fields or buttons you may have missed
```

This catches the Pinpoint loop (51 elements every step) and directly suggests webSearch.

### Layer 3: Web Search Tool (Brave Search API)

Available as `webSearch` tool. The AI can call it proactively or in response to the unchanged screen warning.

## When to Search vs. When to Act

1. **Act immediately** when the app is well-known (Messages, Maps, Settings) or the interaction is obvious (text field + button, search bar)
2. **Read first** when encountering an unfamiliar app — CoAT reasoning forces this
3. **Auto-triggered search** when the screen hasn't changed after 3 actions — the agent is clearly not making progress
4. **Manual search** when the AI recognizes it doesn't understand an interface

## Research Context

### Screen Understanding in Computer-Use Agents

| Agent | Approach | Lesson |
|-------|----------|--------|
| **Claude Computer Use** | Post-action verification: "take a screenshot and evaluate if you achieved the right outcome." No explicit "read before act" instruction. | Verification catches errors but doesn't prevent them |
| **OpenAI Operator (CUA)** | Perception-reasoning-action loop with learned reasoning via RL. Planning is learned, not prompt-engineered. | Learning > prompting for complex reasoning |
| **CoAT** (EMNLP 2024, arXiv:2403.02713) | Structured 4-step reasoning before every action: screen description, action think, next action, predicted outcome. | Structured format matters more than raw reasoning capability |
| **PAL-UI** (arXiv:2510.00413) | Dual-level summarization + retrieval of past screenshots during planning. | Agents forget what earlier screens looked like |
| **Smol2Operator** (HuggingFace) | Two-phase training: element localization → agentic reasoning. Transforms reactive to proactive. | Localization (knowing what's interactive) is a prerequisite for planning |

### Mobile Agents + Web Search (gap in literature)

| Paper | Approach | Gap |
|-------|----------|-----|
| **MobileRAG** (arXiv:2509.03891) | InterRAG (web), LocalRAG (device), MemRAG (history). 10.3% over SOTA. | Factual retrieval, not UI interaction understanding |
| **AppAgent v2** (arXiv:2408.11824) | Pre-exploration → knowledge base → retrieval at deployment | Can't handle never-seen apps |
| **Adaptive-RAG** (NAACL 2024) | Classifier routes: simple → LLM, complex → retrieval | Applied to QA, not mobile agents |
| **Browser agents** (WebArena, SeeAct) | No search — rely entirely on visual understanding | Same limitation as mobile agents |

### The novel contribution

No mobile GUI agent combines: (1) structured screen reasoning (CoAT), (2) behavioral triggers for web search (unchanged screen detection), and (3) real-time web search for understanding unfamiliar app interactions. This three-layer approach is both practical and publishable.

### Key research finding

From "Does Chain-of-Thought Reasoning Help Mobile GUI Agents?" (arXiv:2503.16788): **structured output format matters more than raw reasoning capability.** This validates our CoAT-style prompt approach — forcing the AI to describe the screen before acting is more effective than hoping it reasons better.

### Related work
- **Agentic RAG Survey** (arXiv:2501.09136)
- **From Web Search towards Agentic Deep Research** (arXiv:2506.18959)
- **Anthropic Computer Use Best Practices** (platform.claude.com)
- **GUI Agent Survey** (arXiv:2504.19838)
