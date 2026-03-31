# Future Improvements

Items that are technically possible but deferred for now.

## Core Problems to Solve

### 1. Coordinate accuracy (tap precision)
The agent sometimes misses UI targets — taps the wrong element, misses small buttons, or clicks near but not on the target. This is the #1 failure mode.
- **Root cause:** LLM estimates coordinates from screenshots, which is inherently imprecise
- **Potential fixes:**
  - Grid overlay grounding (`--grounding grid`) — visual reference lines help the LLM estimate
  - Zoom-and-tap grounding (`--grounding zoomclick`) — zoom into the area first for precise targeting
  - Use `getUIElements` + `tapText` instead of coordinate taps whenever possible
  - Increase screenshot resolution sent to LLM for finer detail
  - Element detection via view hierarchy bounds — tap by exact pixel bounds instead of guessing

### 2. App-specific understanding (unfamiliar UIs)
The agent struggles with apps it hasn't seen before — doesn't know how to play games, navigate custom UIs, or find non-standard input fields (e.g., LinkedIn search, Pinpoint game hints).
- **Root cause:** LLM relies on visual understanding of screenshots. Custom/unique app layouts have no standard pattern to follow.
- **Potential fixes:**
  - App-specific knowledge base (AppAgent's exploration phase — learn app UI before executing tasks)
  - Few-shot examples in the system prompt for specific apps
  - Let users teach the agent: "to search on this app, tap the magnifying glass at top right"
  - Memory of past app interactions: if the agent learned that LinkedIn search is at the top, save that pattern

## Dynamic Island

- **Auto-expand on question** — iOS only auto-expands Dynamic Island for push notification updates, not local `ActivityKit` updates. Would require push-based updates (`pushType: .token`) with APNs infrastructure.

- **Pulsing/animated keyline border** — `keylineTint()` only accepts a static color. No animation APIs in Live Activities. Could simulate flash by rapidly toggling content state.

- **Taller expanded view** — Hard capped at ~160pt by iOS. No workaround. Use `contentMargins`, `belowIfTooWide`, and `priority` to maximize available space.

- **Background polling** — Companion app polling stops when iOS suspends it in background. Fix: push notifications for task start events, or `BGAppRefreshTask`.

## Human-in-the-Loop

- **Code-level enforcement** — Pre-execution hooks that force `askUser` before certain tools (e.g., any action in Messages app, any delete action).

- **Richer question types** — Free-text input, yes/no confirmation, or image-based choices beyond multiple-choice.

## Efficiency

- **Eval task suite** — Define 5-15 repeatable tasks, run across all agent modes, produce comparison graphs for presentation.

- **JSONL structured per-step logging** — Per-step logs with wall time, tokens, vision vs text-only, success/fail for generating benchmark data.

- **Screenshot compression** — Phone screenshots are 8MB. Resize to ~600px wide before sending to LLM for faster AI response times.

## Action Shortcuts (compound tools)

- **`typeAndSubmit` tool** — IMPLEMENTED. Tap field + type + press enter in one call.
- **`searchIn` tool** — Open search bar + type query + submit. Common pattern across Maps, Safari, App Store, Settings.
- **`fillForm` tool** — Tap field, type, tap next field, type, submit. For multi-field forms.

## Wireless / Remote Operation

- **Same network wireless** — Currently requires USB cable for Maestro bridge. Investigate if Maestro bridge can work over Wi-Fi (XCTest runner accessible via network?). Would allow phone to be untethered during demos.

- **Different network / no computer** — Run the agent server in the cloud. Phone connects to cloud server over the internet. Would require: cloud-hosted server, port forwarding or tunnel (ngrok/Cloudflare Tunnel), and a way to bridge Maestro commands to the phone remotely. Much harder — likely needs a different architecture.

## Agentic Features

- **MCP tool integration** — Connect to external MCP servers (calendar, email, Slack, etc.) so the agent can pull data from other services, not just what's on screen.

- **Recurring/scheduled tasks** — "Remind me to text Mom at 5pm" or "Every morning, check my calendar and read me my schedule." Requires a background scheduler that triggers the agent at specific times. Server + bridge must be running at trigger time.

- **On-screen Q&A (Siri-style overlay)** — Instead of opening Safari to Google something, answer the user's question directly and display it on screen — like Siri's answer cards but powered by GPT/Claude. Could use an overlay view in the companion app or a notification.

## Reactive Triggers (event-driven automation)

- **Message-based triggers** — "When Kenny sends me a link, open it automatically." Agent monitors notifications or periodically checks Messages for new content matching a rule. When triggered, it acts immediately without the user pressing the Action Button.
- **Time-sensitive automation** — "When I get a tennis court booking link, sign up immediately." The agent reacts to incoming messages with urgency — opens the link, fills the form, submits before spots fill up. Combines notification monitoring + multi-step automation.
- **Rule engine** — User defines trigger rules: `{ when: "message from Kenny contains link", do: "open the link in Safari" }`. Stored in a `rules.json` file. Agent checks rules against incoming events.
- **Notification monitoring** — Read iOS notifications via the view hierarchy or accessibility APIs. When a notification matches a rule, wake the agent and execute the associated task.
- **This is what makes it OpenClaw for mobile** — OpenClaw reacts to messages on WhatsApp/Telegram/Slack. We'd react to iOS notifications and Messages. Same concept, native mobile implementation.

## App Replacement

- **Native App Intent for Action Button** — Replace the Shortcuts-based Action Button with a native `AppIntent` in the companion app. Would allow: `SFSpeechRecognizer` for voice capture, custom listening UI, direct Live Activity start, and no dependency on the Shortcuts app. The companion app becomes the single entry point: Action Button press, voice input, agent control, Dynamic Island progress, stop button — all in one app.
