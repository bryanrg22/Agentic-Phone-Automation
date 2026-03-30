# Future Improvements

Items that are technically possible but deferred for now.

## Dynamic Island

- **Auto-expand on question** — iOS only auto-expands Dynamic Island for push notification updates, not local `ActivityKit` updates. Would require migrating from polling-based updates to push-based (`pushType: .token`), which needs Apple Push Notification Service setup + server-side push infrastructure.

- **Pulsing/animated keyline border** — `keylineTint()` only accepts a static color. No animation APIs are available in Live Activities. Could simulate a flash by rapidly toggling content state, but not a smooth pulse.

- **Taller expanded view** — Hard capped at ~160pt by iOS. No workaround. Use `contentMargins`, `belowIfTooWide`, and `priority` to maximize available space.

- **Background polling** — Companion app polling stops when iOS suspends it in background. Live Activities only get created if the app is in foreground when the task starts. Fix: push notifications for task start events, or use `BGAppRefreshTask`.

## Human-in-the-Loop

- **Code-level enforcement** — Currently relies on prompt instructions for when to call `askUser`. Could add pre-execution hooks in `agent.mjs` that force `askUser` before certain tools (e.g., any action in Messages app, any delete action).

- **Richer question types** — Currently only supports multiple-choice. Could add free-text input, yes/no confirmation, or image-based choices.

## Efficiency

- **Eval task suite** — Define 5-15 repeatable tasks, run across all agent modes, produce comparison graphs for presentation.

- **JSONL structured logging** — Per-step logs with wall time, tokens, vision vs text-only, success/fail for generating benchmark data.

- **Screenshot compression** — Phone screenshots are 8MB. Resize to ~600px wide before sending to LLM for faster AI response times.

## Action Button

- **Native App Intent** — Replace the Shortcuts-based Action Button with a native `AppIntent` in the companion app. Would allow voice recognition via `SFSpeechRecognizer`, custom listening UI, and direct chaining into Live Activity start.
