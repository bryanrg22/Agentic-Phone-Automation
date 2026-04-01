# iOS Companion App

**Date:** April 1, 2026

The MobileAgentCompanion app runs on your iPhone alongside the agent. It provides real-time status monitoring via the Dynamic Island and a full interface for viewing task history and managing agent memory.

## Features

### Status Tab
Real-time view of the agent's current state, updated every 500ms via HTTP polling to the Mac server.

**States:**
- **Not connected** — Enter your Mac's hostname and tap Connect
- **Connecting** — Spinner while establishing connection
- **Idle** — Connected, waiting for a task. "Hold the Action Button and speak a command"
- **Active** — Shows task name, current step, phase (Thinking/Acting/Observing), elapsed time, agent's current thought, progress bar with phase-colored fill, and current tool name as a badge
- **Complete** — Green checkmark with step count and total time

**Phase indicators:**
| Phase | Icon | Color |
|-------|------|-------|
| Thinking | Brain | Blue |
| Acting | Lightning bolt | Orange |
| Observing | Eye | Purple |
| Complete | Checkmark | Green |
| Failed | X mark | Red |
| Waiting (HITL) | Person with question mark | Yellow |

### History Tab
Browse all completed tasks, grouped by day (Today, Yesterday, older dates).

**Features:**
- Task name, summary, success/fail status
- Step count, completion time, model used
- Timestamp for each task
- Pull-to-refresh to sync new tasks from server
- **Offline cache** — History is stored in UserDefaults. Previously synced tasks are visible even when disconnected from the server

**Data source:** `logs/tasks.jsonl` on the Mac, served via `GET /history` endpoint.

### Memory Tab
View, edit, and delete facts the agent has learned about you.

**Features:**
- All saved facts displayed with dates
- **Edit** (pencil icon) — Opens a half-sheet text editor to modify any fact. Changes are saved to the Mac's `memories/user.md` file
- **Delete** (trash icon) — Removes a fact from both the app and the server file. Use this to clean up duplicates and stale data
- Pull-to-refresh to sync from server
- **Offline cache** — Memories are stored in UserDefaults. Visible offline, syncs when connected

**Data source:** `memories/user.md` on the Mac, served via `GET /memories`, `POST /memories/delete`, `POST /memories/edit` endpoints.

**Memory hygiene tips:**
- Delete weather/prices/scores — they go stale in hours
- Delete duplicate entries (the agent sometimes saves the same fact multiple times)
- Edit vague facts to be more specific
- Keep: contact disambiguation, user preferences, recurring patterns

### Dynamic Island
Shows agent progress as a Live Activity on the lock screen and Dynamic Island.

**Features:**
- Task name, step count, elapsed time, agent thought
- Phase icon updates in real-time
- **Stop button** in expanded view — cancels the running task
- **Human-in-the-loop** — When the agent asks a question, options appear with a yellow tint. Tap to respond
- Completion shows green checkmark for 4 seconds before dismissing

## Architecture

```
iPhone                              Mac (same Wi-Fi)
──────                              ────────────────
Companion App                       Frontend Server (port 8000)
  ├── Status tab ──── polls ────→  GET /status (every 500ms)
  ├── History tab ─── fetches ──→  GET /history (on tab switch)
  ├── Memory tab ──── fetches ──→  GET /memories
  │   ├── Edit ────── posts ────→  POST /memories/edit
  │   └── Delete ──── posts ────→  POST /memories/delete
  └── Dynamic Island                  ↑
      ├── Stop ────── posts ────→  POST /stop
      └── Respond ─── posts ────→  POST /respond

Action Button Shortcut
  └── Voice → POST /task ────────→  POST /task → spawns agent.mjs
```

## Server Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/status` | GET | Current agent state (phase, step, thought, etc.) |
| `/task` | POST | Start a new task from voice/shortcut |
| `/stop` | POST | Stop the running agent |
| `/respond` | POST | Send user's HITL choice to the agent |
| `/history` | GET | All completed tasks from `logs/tasks.jsonl` |
| `/memories` | GET | Parsed memory facts from `memories/user.md` |
| `/memories/delete` | POST | Delete a memory by fact text |
| `/memories/edit` | POST | Edit a memory (old fact → new fact) |
| `/register-push-token` | POST | Register APNs token for Live Activities |

## Local Caching

Both history and memories use UserDefaults for offline persistence:

1. **On app launch:** Load cached data from UserDefaults (instant, no network)
2. **On tab switch:** Fetch from server, merge with cache, save updated data
3. **On pull-to-refresh:** Same as tab switch
4. **When offline:** Cached data remains visible. Edits/deletes require connection

## Setup

1. Build and deploy from Xcode:
   ```bash
   open ios/MobileAgentCompanion/MobileAgentCompanion/MobileAgentCompanion.xcodeproj
   ```
   Select your iPhone as target, Cmd+R.

2. On first launch, enter your Mac's hostname (e.g., `Bryans-MacBook-Pro.local`) and tap Connect.

3. The hostname is saved — the app auto-connects on future launches.

4. Make sure the frontend server is running on your Mac:
   ```bash
   node frontend/server.mjs --provider openai
   ```

5. iPhone and Mac must be on the same Wi-Fi network.
