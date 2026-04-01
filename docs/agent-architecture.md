# Agent Architecture Reference

Technical reference for the agent loop in `agent.mjs` as of March 31, 2026.

## Step Lifecycle

Each step follows this exact sequence:

```
1. Stuck detection (check last 3 actions for duplicates or coordinate clusters)
2. Vision gate decision (vision-gated mode only)
3. Context injection (rolling summary + UI labels for single-image/vision-gated)
4. LLM call → AI returns tool_calls
5. Execute each tool sequentially
6. Track action keys for stuck detection
7. Auto-capture flag set if action tool was used
8. Settle delay (350ms, navigation actions on physical device only)
9. Screenshot + hierarchy fetch in parallel (Promise.all)
10. UI elements bundled with screenshot message
11. Step timing logged
12. 500ms inter-step sleep
```

## Tool Execution Paths

### Coordinate-based tap: `tap(x, y)` — ~100ms
```
AI provides percentages → convert to pixels → touchPoint(px, py) via HTTP
```
Fastest option. AI gets coordinates from auto-bundled UI elements.

### Text-based tap: `tapText("label")` — ~600ms
```
viewHierarchy() (500ms) → search for label → touchPoint(cx, cy) (100ms)
```
Fetches hierarchy redundantly (already bundled with screenshot). If label not found, returns error immediately. No Maestro CLI fallback.

### Compound: `typeAndSubmit(elementText, text, submitKey)` — ~4-6s
```
tapText(elementText) → sleep(500) → inputText(text) → sleep(300) → send logic
```
For `submitKey: "send"`: hierarchy lookup for send button → tap at found coordinates → 500ms settle. Falls back to `pressKey('enter')` if not found. Logs the lookup result.

### Auto-bundled UI elements
Every auto-captured screenshot includes a parallel-fetched hierarchy with element positions:
```
UI elements on screen:
- "Send" at (90%, 56%)
- "Emiliano" at (18%, 21%)
- "Message" at (50%, 95%)
Use tap(x, y) with coordinates above for precise tapping.
```

## Settle Delay Policy

| Action | Settle Delay | Why |
|--------|-------------|-----|
| `tap`, `tapText`, `scroll`, `swipe` | 350ms | iOS nav transitions (330ms) |
| `typeAndSubmit` | 350ms + 500ms internal | Send animation + transition |
| `openApp` | None | App loading, not an animation |
| `inputText`, `pressKey` | None | No visual transition |
| Simulator (any action) | None | Instant rendering |

## Stuck Detection

Triggers after 3 consecutive matching actions:

1. **Exact match:** Identical action key strings
2. **Coordinate cluster:** Same tool name, x-coordinates within 10%, y-coordinates within 10%
3. **Same tapText target:** Same tool name + same text argument

When triggered, injects a warning message telling the AI to try `getUIElements` or a different approach.

## Screenshot + Hierarchy Parallel Fetch

```javascript
const [buffer, uiElementsText] = await Promise.all([
  screenshotPromise,    // HTTP GET /screenshot (~162ms)
  hierarchyPromise,     // HTTP POST /viewHierarchy (~500ms)
]);
```

Total time: ~500ms (limited by slower call, not sum).

### Cold start
First `viewHierarchy()` on a new app takes ~2-3s as iOS builds the accessibility tree. Subsequent calls: 0.5-0.9s.

## Error Handling

### Tool errors
```javascript
const execStart = Date.now();
try {
  result = await executeTool(toolName, toolArgs);
} catch (e) {
  const execMs = Date.now() - execStart;  // Real time, not hardcoded 0
  result = `Error: ${e.message}`;
  entry.tools.push({ name: toolName, time: execMs / 1000, error: true });
}
```

Error messages are sent back to the AI as tool results. The AI decides how to recover.

### tapText not found
Returns immediately: `ERROR: Element "X" not found in view hierarchy.`
No Maestro CLI fallback. ~0ms penalty.

### Hierarchy fetch failure (auto-bundle)
Falls back to screenshot-only. AI uses visual coordinate estimation.

## Memory System

- **Semantic memory** (`memories/user.md`): Loaded into system prompt. Agent writes via `saveMemory` tool.
- **Episodic memory** (`logs/tasks.jsonl`): Append-only task history. Agent reads via `recallHistory`.
- Memory from previous runs influences behavior (e.g., skipping askUser when user preference is known).

## Key Metrics per Step

| Component | Typical Time | Notes |
|-----------|-------------|-------|
| AI inference | 1.5-3.5s | Model/provider dependent |
| tap (coordinate) | 0.3-0.7s | Direct HTTP touchPoint |
| tapText | 0.5-1.3s | Hierarchy fetch + touchPoint |
| typeAndSubmit | 4-6s | Type + send + internal settle |
| Screenshot + hierarchy | 0.8-2.5s | Parallel fetch, cold start ~3s |
| Settle delay | 0 or 350ms | Navigation actions only |
| Inter-step sleep | 500ms | Fixed |
