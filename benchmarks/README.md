# Benchmarks

## Overview

We test multiple improvement techniques against a baseline to measure speed and accuracy gains. Each technique is toggled via command-line flags so results are cleanly comparable. All findings are research-backed (see `research-findings.md`).

## Prerequisites

Before running benchmarks, you need:
1. **Maestro bridge running** in a separate terminal:
   ```bash
   export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
   maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
   ```
2. **Phone unlocked, plugged in via USB**
3. **API keys** in `.env` (`OPENAI_API_KEY` and/or `GEMINI_API_KEY`)

## Baselines (what we compare against)

| # | Baseline | Flag | What it measures |
|---|----------|------|-----------------|
| 1 | Raw screenshot, no modifications | `--grounding baseline` | Default tap accuracy + speed |
| 2 | Single-image mode (rolling summary) | `--agent-mode single-image` | Default context management |
| 3 | OpenAI provider | `--provider openai` | Default LLM quality |
| 4 | Uncompressed screenshots | (no `--compress`) | Default image size + AI response time |

## Improvements to test against baselines

| # | Improvement | Flag | What we expect | Research basis |
|---|------------|------|---------------|----------------|
| 1 | **Grid overlay** | `--grounding grid` | Fewer wrong taps (spatial reference) | AppAgent (Tencent, CHI 2025) |
| 2 | **ZoomClick** | `--grounding zoomclick` | Better accuracy on small targets (+48pp in research) | ZoomClick (Princeton, 2025) |
| 3 | **Screenshot compression** | `--compress` | Faster AI response (8MB → 150KB, same accuracy) | ScreenSpot-Pro (2025), Anthropic/OpenAI docs |
| 4 | **Vision-gated mode** | `--agent-mode vision-gated` | Fewer screenshots, lower token cost | SecAgent (2025) |
| 5 | **Gemini provider** | `--provider gemini` | Faster response, lower cost | — |
| 6 | **Direct HTTP** | `--phone` | Faster tool execution (already implemented) | XCTest runner HTTP API |

## Test Tasks

| # | Task Command | Difficulty | Why this task |
|---|-------------|-----------|---------------|
| 1 | `"open Photos and tap the most recent photo"` | Hard | Small target, close to search icon |
| 2 | `"open Maps and search for USC"` | Medium | Search bar at bottom (iOS-specific) |
| 3 | `"open Settings and tap Wi-Fi"` | Easy | Large, clear text target |
| 4 | `"open Safari and go to google.com"` | Medium | Thin target across full width |
| 5 | `"open Reminders and create a reminder called Buy groceries"` | Hard | Multi-step, small + button |

## Test Matrix

Run each task with each configuration. Record steps, time, wrong taps, and success.

| Task | baseline | grid | zoomclick | compress | grid+compress | zoomclick+compress |
|------|----------|------|-----------|----------|---------------|-------------------|
| Photos: tap most recent | | | | | | |
| Maps: search USC | | | | | | |
| Settings: tap Wi-Fi | | | | | | |
| Safari: go to google.com | | | | | | |
| Reminders: create reminder | | | | | | |

That's 5 tasks × 6 configurations = **30 runs**.

## How to Run

```bash
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"

# ─── BASELINE (no improvements) ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding baseline --max-steps 15

# ─── GRID OVERLAY ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding grid --max-steps 15

# ─── ZOOMCLICK ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding zoomclick --max-steps 15

# ─── COMPRESSION ONLY ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding baseline --compress --max-steps 15

# ─── GRID + COMPRESSION ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding grid --compress --max-steps 15

# ─── ZOOMCLICK + COMPRESSION ───
node agent.mjs "open Maps and search for USC" --phone --provider openai --grounding zoomclick --compress --max-steps 15
```

## Metrics to Record

For each run, record in the results file:
- Task name
- Grounding mode + flags
- Provider + model
- Total steps
- Total time (seconds)
- Steps with wrong taps (coordinate errors)
- Task completed successfully (yes/no)
- AI time vs tool time vs screenshot time breakdown
- Screenshot sizes (KB)

## Results Files

- `baseline-results.md` — Raw screenshot results (the control)
- `grid-results.md` — Grid overlay results
- `zoomclick-results.md` — ZoomClick results
- `comparison.md` — Side-by-side comparison table + findings
- `research-findings.md` — Research papers and key findings backing each technique
