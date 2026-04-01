# Human-in-the-Loop: When to Ask vs. When to Execute

**Date:** April 1, 2026

## The Problem

The agent re-confirms tasks the user already explicitly requested:

```
User: "Text Emiliano the current weather in Paris"
Agent: "Send a text to Emiliano with the current weather in Paris once I look it up?"
         — options: Yes, send it / No, cancel
```

The user's command IS the confirmation. Re-asking wastes 3-5 seconds, adds friction, and — per research — **degrades user trust and perceived competence**.

## How Production Systems Handle This

### Claude Code
Tiered model based on **reversibility**: read-only operations execute freely, write operations require approval unless allowlisted. Key heuristic: safe/reversible → auto-execute, destructive/irreversible → pause.

### OpenAI Operator
Defines "Confirmation Required Actions" (CRAs): purchases, sending messages, deleting data, account changes. Key rule: **if the user's instruction already specifies the exact action, Operator executes without re-asking.**

### Voice Assistants (Siri, Alexa, Google)
- Siri: "Text Mom I'm on my way" → **sends immediately**, no confirmation. Only asks when contact is ambiguous or transcription confidence is low.
- Alexa: Confirms purchases but not information lookups or smart home commands.
- Google Assistant: Same pattern — explicit commands execute, ambiguous ones confirm.

### Browser Agents (Multion, Browserbase)
Trigger HITL only on: (1) ambiguity, (2) authentication/login walls, (3) payment flows. Never re-confirm unambiguous directives.

### Research
AAAI 2024 workshop paper "When to Ask for Help" identifies three triggers:
1. **Ambiguity** in user intent
2. **High-stakes irreversibility** (money, deletion)
3. **Low agent confidence**

Key finding: re-confirming an unambiguous explicit instruction degrades user trust.

## Rules for Our Agent

### DO ask when:
- **Contact is ambiguous** — multiple people match (e.g., two "Emiliano" contacts)
- **Money is involved** — purchases, payments, subscriptions
- **Deletion** — removing messages, photos, data
- **The task requires interpretation** — user said something vague that the agent needs to clarify
- **Agent is uncertain** — low confidence about what the user wants

### DO NOT ask when:
- **User gave an explicit command** — "Text Emiliano hello" = send it. "Search for tacos" = search.
- **Task is clear and non-destructive** — opening apps, searching, navigating
- **Memory already has the answer** — agent knows which Emiliano from prior tasks
- **Re-confirming what the user just said** — never parrot the task back as a question

### The key test:
> **Did the user's command already specify WHAT to do, WHO to do it to, and the CONTENT?**
> If yes → execute. If any part is missing or ambiguous → ask about ONLY the ambiguous part.

Examples:

| Command | Ask? | Why |
|---------|------|-----|
| "Text Emiliano the weather in Paris" | **No** | Who (Emiliano), what (text), content (weather) — all specified |
| "Send a message to Emiliano" | **Yes** — "What should the message say?" | Content missing |
| "Text someone hello" | **Yes** — "Who should I text?" | Recipient ambiguous |
| "Order me an Uber" | **Yes** — "Confirm ride to [destination]?" | Money involved |
| "Delete all my photos" | **Yes** — "Are you sure? This cannot be undone." | Destructive + irreversible |
| "Open Spotify" | **No** | Non-destructive navigation |
| "Play lofi beats on Spotify" | **No** | Clear, non-destructive |

## Memory Concerns

### What the agent saved in this run:
```
"User approved sending a text to Emiliano with the current weather in Paris once looked up."
"Paris weather looked up in Weather: 46°F and Cloudy, high 54°, low 46° on 2026-04-01."
```

### Problems:
1. **Ephemeral data saved as permanent memory** — "Paris is 46°F" is true for one hour. Tomorrow it's wrong. Weather, prices, scores, and time-sensitive data should NEVER be saved to memory.
2. **Approval patterns are too specific** — "User approved sending weather in Paris to Emiliano" is too narrow to be useful. Better: "User generally approves sending texts to Emiliano without re-confirmation."
3. **Duplicate memories** — The memory file has 4 copies of "When asked to text Emiliano what school they go to, user approved sending exact dictated text: 'USC'." and 3 copies of the Emiliano contact disambiguation.

### Memory rules (proposed):
- **Save:** User preferences, contact disambiguation, recurring patterns
- **Don't save:** Weather, prices, scores, timestamps, one-time approvals, anything that changes daily
- **Deduplicate:** Before saving, check if a similar fact already exists
