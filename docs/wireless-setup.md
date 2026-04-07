# Wireless Setup Guide

**Date:** April 6, 2026

How to run the agent wirelessly — no USB cable needed during operation.

## Prerequisites

- pymobiledevice3 installed (`pip install pymobiledevice3`)
- Maestro iOS device bridge installed
- Companion app deployed to iPhone via Xcode
- iPhone and Mac on the same Wi-Fi network (enterprise networks may block Bonjour — use Personal Hotspot as fallback)

## One-Time Setup (USB required)

```bash
# 1. Enable Wi-Fi connections on the device
pymobiledevice3 lockdown wifi-connections --state on

# 2. Build and install the XCTest runner
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
```

If the maestro build fails with provisioning profile errors, rebuild manually:
```bash
cd ~/.maestro/maestro-ios-xctest-runner
xcodebuild build-for-testing \
  -project maestro-driver-ios.xcodeproj \
  -scheme maestro-driver-ios \
  -destination "id=00008130-0008249124C1401C" \
  -allowProvisioningUpdates
```

## Wireless Operation (no USB)

### Terminal 1: Wi-Fi tunnel (keeps runner alive)
```bash
sudo pymobiledevice3 remote start-tunnel -t wifi -p tcp
```
- Select your device when prompted (pick the non-link-local address, e.g., `2607:...` or `172.20.10.x`)
- Keep this terminal open — the tunnel stays alive as long as it runs

### Terminal 2: Maestro bridge
```bash
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
```
- Start with USB connected
- Once you see "Ready!" → unplug USB
- The Wi-Fi tunnel maintains the connection

### On iPhone
1. Open MobileAgentCompanion → tap **On-Device**
2. Tap gear icon → enter your **OpenAI API key**
3. Verify **green dot** ("Runner online port 22087")
4. Type a task or press the **Action Button** to speak one

## Troubleshooting

### "No devices were found during bonjour browse"
Your network blocks Bonjour/mDNS (common on enterprise/university Wi-Fi like USC, Yale).
**Fix:** Turn on iPhone's Personal Hotspot, connect Mac to it, then run the tunnel command.

### Tunnel closes when USB disconnects
You created a USB tunnel instead of a Wi-Fi tunnel.
**Fix:** Use `-t wifi` flag: `sudo pymobiledevice3 remote start-tunnel -t wifi -p tcp`

### Runner shows offline after unplug
The maestro bridge lost connection.
**Fix:** Make sure the Wi-Fi tunnel (Terminal 1) is still running. Restart the maestro bridge.

### Provisioning profile errors
```bash
cd ~/.maestro/maestro-ios-xctest-runner
xcodebuild build-for-testing \
  -project maestro-driver-ios.xcodeproj \
  -scheme maestro-driver-ios \
  -destination "id=YOUR_UDID" \
  -allowProvisioningUpdates
```

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Mac (on same Wi-Fi / hotspot)                           │
│                                                          │
│  Terminal 1: pymobiledevice3 Wi-Fi tunnel               │
│    → maintains developer services connection wirelessly  │
│                                                          │
│  Terminal 2: maestro-ios-device bridge                   │
│    → launched runner initially, keeps it alive            │
└──────────────────┬───────────────────────────────────────┘
                   │ Wi-Fi (no USB)
┌──────────────────▼───────────────────────────────────────┐
│  iPhone                                                   │
│                                                          │
│  OnDeviceAgent.swift (runs in companion app)             │
│    → calls OpenAI/Gemini API over cellular/Wi-Fi          │
│    → talks to XCTest runner at localhost:22087             │
│    → controls other apps (taps, types, screenshots)       │
│    → updates Dynamic Island via Live Activities           │
│    → saves memory + history to local Documents dir        │
│                                                          │
│  Action Button → "Run Agent Task" App Intent             │
│    → Dictate Text → OnDeviceAgent.run(task:)              │
└──────────────────────────────────────────────────────────┘
```

## What's Next: Remote Server

Currently the Mac must be on the same Wi-Fi network as the iPhone. The next step is making the Mac reachable from anywhere — so you can be on campus and the Mac is at home.

Options being researched:
1. **Tailscale / WireGuard** — VPN mesh that makes the Mac's tunnel reachable from any network
2. **Cloudflare Tunnel** — expose the XCTest runner port through a public endpoint
3. **Hosted Mac service** — MacStadium Orka, Scaleway — rent a Mac that runs the tunnel 24/7

See `docs/one-device-transition-research.md` for the full roadmap.
