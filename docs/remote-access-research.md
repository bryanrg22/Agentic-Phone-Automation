# Remote Access: Controlling Your iPhone from Anywhere

**Date:** April 7, 2026

Research on making the agent work when the Mac is at home and you're on the other side of the world.

## The Goal

Currently: Mac and iPhone must be on the same WiFi network. The pymobiledevice3 tunnel uses Bonjour (local network only) for device discovery.

Target: You're in Japan (or anywhere with internet). Your Mac is at home. Your iPhone is at home connected to the Mac wirelessly. You press the Action Button on a second device or trigger a task remotely, and the agent executes on the home iPhone.

Or more practically: your iPhone is with you, the Mac is at home, and the iPhone connects to the Mac's XCTest runner over the internet instead of local WiFi.

## The Core Problem

The XCTest runner is an HTTP server at `localhost:22087` on the Mac (forwarded from the iPhone via the tunnel). The iPhone's OnDeviceAgent connects to `localhost:22087`. To go remote, we need to make that port reachable from any network.

---

## Approach 1: Cloudflare Tunnel (RECOMMENDED)

**Best for this project because it requires NO VPN on the iPhone.**

### How It Works

Run `cloudflared` on the Mac. It creates an outbound-only connection to Cloudflare's edge network and exposes `localhost:22087` as a public HTTPS URL like `https://xctest.yourdomain.com`. The iPhone app changes one URL string — no VPN, no battery drain, no configuration.

### Setup

```bash
# 1. Install cloudflared on Mac
brew install cloudflared

# 2. Authenticate (one-time)
cloudflared tunnel login

# 3. Create a tunnel
cloudflared tunnel create xctest

# 4. Route a DNS record to the tunnel
cloudflared tunnel route dns xctest xctest.yourdomain.com

# 5. Run the tunnel
cloudflared tunnel run --url http://localhost:22087 xctest
```

### What Changes in the App

`OnDeviceAgent.swift` currently connects to:
```swift
"http://localhost:\(xcTestPort)/touch"
```

With Cloudflare Tunnel, it becomes:
```swift
"https://xctest.yourdomain.com/touch"
```

Add the remote URL as a setting in the companion app alongside the existing XCTest port field.

### Authentication

Cloudflare Access (free tier) can require authentication before allowing requests through the tunnel. Options:
- One-time PIN sent to your email
- GitHub/Google SSO
- Service token (API key in the request header)

For the companion app, a service token is simplest — add a header to every XCTest request:
```swift
req.setValue("Bearer <token>", forHTTPHeaderField: "CF-Access-Client-Id")
req.setValue("<secret>", forHTTPHeaderField: "CF-Access-Client-Secret")
```

### Pros
- **No VPN on iPhone** — just HTTPS requests to a domain. No single-VPN conflict, no battery drain
- **Free** — tunnels have no bandwidth limits. Need a domain ($2/year for .xyz on Cloudflare)
- **Auto-reconnect** — `cloudflared` maintains persistent outbound connections and reconnects automatically
- **TLS included** — all traffic encrypted end-to-end via Cloudflare's edge
- **Authentication built in** — Cloudflare Access free tier supports it

### Cons
- Need to own a domain on Cloudflare
- Mac must stay awake (`caffeinate` or disable sleep in Energy Saver)
- Adds 10-50ms latency (Cloudflare edge overhead). Japan-to-US: ~150-200ms total RTT. Negligible — LLM calls take 1-3s
- If Mac sleeps, `cloudflared` stops. Need a `launchd` service for reliability

### Keep-Alive Setup

```bash
# Create a launchd plist for auto-start
cat > ~/Library/LaunchAgents/com.cloudflare.tunnel.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.tunnel</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string>
        <string>tunnel</string>
        <string>run</string>
        <string>xctest</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.cloudflare.tunnel.plist
```

---

## Approach 2: Tailscale (VPN Mesh)

### How It Works

Tailscale creates a WireGuard-based mesh VPN. Install on both Mac and iPhone. Each device gets a stable `100.x.x.x` IP. The iPhone reaches the Mac at `http://100.x.x.x:22087` from anywhere in the world.

### Setup

1. Install Tailscale on Mac (`brew install tailscale`)
2. Install Tailscale on iPhone (App Store)
3. Sign in with same account on both
4. Change `OnDeviceAgent.swift` to connect to `http://100.x.x.x:22087`

### Pros
- Simplest setup (3 steps, zero config networking)
- Peer-to-peer connections (1-3ms overhead when direct, 20-100ms via relay)
- Free for personal use (100 devices)
- VPN On Demand keeps connection alive on iOS

### Cons
- **Single VPN limitation on iOS** — iOS allows only one VPN at a time. If you use a corporate or travel VPN, Tailscale disconnects. This is a hard iOS limitation with no workaround.
- **Battery drain** — Tailscale maintains NAT traversal constantly. Expect 5-15% more drain per day on iPhone (known issue, tracked at tailscale/tailscale#13615).
- **VPN coexistence** — cannot run alongside another VPN. In Japan on hotel WiFi with a VPN? Tailscale disconnects.

### VPN + XCTest Coexistence

The VPN runs on the iPhone as a network extension. The XCTest runner runs on the Mac. These are on different devices — no conflict. The iPhone app just needs TCP access to the Mac's Tailscale IP.

---

## Approach 3: SSH Reverse Tunnel

### How It Works

Rent a cheap VPS. Run `autossh -R 22087:localhost:22087 user@vps` on the Mac. The VPS exposes port 22087 publicly. iPhone connects to `http://vps-ip:22087`.

### Setup

```bash
# 1. Rent a VPS (DigitalOcean $4/month, Hetzner $3.29/month)

# 2. On VPS: enable remote port forwarding
# Edit /etc/ssh/sshd_config:
#   GatewayPorts yes
# Then: sudo systemctl restart sshd

# 3. On Mac: generate SSH key and add to VPS
ssh-keygen -t ed25519
ssh-copy-id user@vps-ip

# 4. On Mac: start persistent reverse tunnel
autossh -M 0 \
  -o "ServerAliveInterval 30" \
  -o "ServerAliveCountMax 3" \
  -N -R 0.0.0.0:22087:localhost:22087 \
  user@vps-ip
```

### Pros
- Cheapest ($3-5/month for a VPS)
- Most reliable (autossh has been battle-tested for 20+ years, auto-reconnects)
- No VPN needed on iPhone
- Minimal latency overhead (SSH adds ~1-5ms)
- Full control — your infrastructure

### Cons
- Port 22087 exposed to the entire internet. **Must add authentication:**
  - nginx reverse proxy with basic auth or client certificates
  - Token-based auth added to XCTest runner requests
  - iptables whitelist (impractical with mobile IPs)
- More manual setup than Cloudflare or Tailscale
- Need to manage a VPS (updates, security)
- Reconnection takes 30-90 seconds after network drop

---

## Approach 4: ngrok

### How It Works

`ngrok http 22087` on the Mac → public URL `https://abc123.ngrok-free.app` → iPhone connects.

### Pros
- Fastest to test (2 commands)
- No VPN on iPhone

### Cons
- Free tier: 1 GB/month bandwidth (screenshots are large — will hit this fast), random URLs, interstitial warning page
- Paid: $8-20/month for persistent domain and more bandwidth
- No auto-reconnect (need wrapper script)
- More expensive than Cloudflare (which is free)

**Verdict:** Good for a quick demo, not for daily use.

---

## Approach 5: FRP (Fast Reverse Proxy)

### How It Works

Self-hosted ngrok alternative. Run `frps` on a VPS, `frpc` on the Mac. 100k+ GitHub stars.

### Setup

```bash
# On VPS: run frps with config
[common]
bind_port = 7000
dashboard_port = 7500

# On Mac: run frpc
[common]
server_addr = vps-ip
server_port = 7000

[xctest]
type = tcp
local_ip = 127.0.0.1
local_port = 22087
remote_port = 22087
```

### Pros
- Free (open source) + $3-5/month VPS
- Built-in dashboard, TLS, token auth, multiplexing
- More features than SSH tunnel
- No VPN on iPhone

### Cons
- More setup than Cloudflare
- Need to manage VPS
- Less battle-tested than SSH tunnels

---

## Approach 6: Hosted Mac (Cloud)

### The Problem

Cloud Macs solve "Mac must be on" but NOT "iPhone must be connected." You still need a physical iPhone attached to a Mac.

### USB over IP

- **usbfluxd** (Corellium): Redirects usbmuxd over TCP. Can make a local iPhone appear connected to a remote Mac. But: "really, really slow" for symbol transfer. Not suitable for real-time automation.
- iOS 17+ complication: Apple's new USB-Ethernet adapter for developer services "cannot traverse standard internet connections or VPNs — tunnels operate exclusively within local network segments."

### Pricing

| Provider | Config | Cost |
|----------|--------|------|
| Scaleway | M1 Mac mini | ~$80/month |
| Scaleway | M2 Mac mini | ~$108/month |
| MacStadium | M2 Mac mini | ~$79-149/month |
| AWS EC2 | mac2.metal (M2) | ~$468/month (24h minimum) |
| MacinCloud | Dedicated | ~$60-150/month |

**Verdict:** Not viable for our use case. The iPhone must be physically near a Mac. A cloud Mac with no iPhone connected is useless.

---

## Recommendation

### For this project, right now:

**Cloudflare Tunnel** is the clear winner:

| Factor | Cloudflare | Tailscale | SSH Tunnel | ngrok |
|--------|-----------|-----------|------------|-------|
| VPN on iPhone? | No | Yes | No | No |
| Cost | Free (+ domain) | Free | $3-5/month | $8-20/month |
| Setup complexity | Medium | Low | Medium | Low |
| Battery impact | None | 5-15%/day | None | None |
| Auto-reconnect | Yes | Yes | Yes (autossh) | No |
| Auth built in | Yes (Access) | Yes (mesh) | No (add nginx) | Yes |
| Single-VPN conflict | No | Yes | No | No |

The killer advantage: **no VPN on the iPhone.** The companion app just makes HTTPS requests to a URL. No battery drain, no VPN conflicts, no iOS background-kill concerns.

### Implementation Plan

1. **Buy a cheap domain** — `.xyz` domains are $2/year on Cloudflare
2. **Install cloudflared** — `brew install cloudflared` on the Mac
3. **Create tunnel** — 3 commands to set up
4. **Add to companion app** — new setting field: "Remote URL" (e.g., `xctest.yourdomain.com`). When set, use HTTPS to that URL instead of `localhost:port`
5. **Add auth headers** — Cloudflare Access service token in every request
6. **Keep Mac awake** — `launchd` service for `cloudflared` + disable sleep
7. **Keep WiFi tunnel alive** — `launchd` service for `pymobiledevice3 remote start-tunnel`

### The Full Remote Stack

```
┌───────────────────────────────────────────────────┐
│  You (anywhere in the world)                       │
│  iPhone in your pocket                             │
│                                                    │
│  OnDeviceAgent.swift:                              │
│    → LLM calls to OpenAI/Gemini (direct)           │
│    → Automation calls to xctest.yourdomain.com     │
│      (HTTPS through Cloudflare)                    │
└────────────┬──────────────────────────────────────┘
             │ Internet (HTTPS)
             ▼
┌───────────────────────────────────────────────────┐
│  Cloudflare Edge (global)                          │
│    → TLS termination                               │
│    → Access authentication                         │
│    → Routes to cloudflared on your Mac              │
└────────────┬──────────────────────────────────────┘
             │ Outbound tunnel (Mac → Cloudflare)
             ▼
┌───────────────────────────────────────────────────┐
│  Your Mac (at home)                                │
│                                                    │
│  cloudflared:                                      │
│    → Maintains tunnel to Cloudflare edge            │
│    → Forwards requests to localhost:22087           │
│                                                    │
│  pymobiledevice3 WiFi tunnel:                      │
│    → Maintains RemoteXPC tunnel to iPhone           │
│    → TUN interface routes to device                 │
│                                                    │
│  Maestro bridge:                                   │
│    → Keeps XCTest runner alive                      │
│    → Port forwards localhost:22087 → device:22087   │
└────────────┬──────────────────────────────────────┘
             │ WiFi (pymobiledevice3 tunnel)
             ▼
┌───────────────────────────────────────────────────┐
│  Your iPhone (at home, on same WiFi as Mac)        │
│                                                    │
│  XCTest runner (port 22087):                       │
│    → Receives tap/type/screenshot commands          │
│    → Executes via XCUITest framework                │
│    → Returns results                               │
└───────────────────────────────────────────────────┘
```

### Latency Budget

| Segment | Latency |
|---------|---------|
| iPhone → Cloudflare edge | ~10-30ms |
| Cloudflare → Mac (tunnel) | ~10-50ms |
| Mac → iPhone (WiFi tunnel) | ~5-15ms |
| XCTest execution | ~50-300ms |
| **Total automation command** | **~75-395ms** |
| LLM API call (dominates) | ~1,000-3,000ms |

Even from Japan to a US-based Mac, the total RTT adds ~200ms. Since LLM calls take 1-3 seconds, the remote overhead is a small fraction of each agent step. The agent would be slightly slower but fully functional.

---

## What This Enables

With Cloudflare Tunnel:
- **Travel**: Control your iPhone from anywhere. Mac stays at home, always on.
- **Demo anywhere**: Show the agent working remotely at a conference, meeting, or class.
- **True personal assistant**: The Mac becomes invisible infrastructure. You just use your phone.
- **Multi-location**: Eventually, swap in a hosted Mac (Scaleway/MacStadium) and eliminate the home Mac entirely.

## Sources

- [Cloudflare Tunnel Setup](https://developers.cloudflare.com/tunnel/setup/)
- [Cloudflare Zero Trust Pricing](https://www.cloudflare.com/plans/zero-trust-services/)
- [Cloudflare Access Service Tokens](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/)
- [Tailscale VPN On Demand for iOS](https://tailscale.com/docs/features/client/ios-vpn-on-demand)
- [Tailscale Battery Drain Issue](https://github.com/tailscale/tailscale/issues/13615)
- [autossh for Persistent SSH Tunnels](https://medium.com/@souri.rv/autossh-for-keeping-ssh-tunnels-alive-5c14207c6ba9)
- [FRP (Fast Reverse Proxy)](https://github.com/fatedier/frp)
- [pymobiledevice3 Protocol Layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md)
- [usbfluxd — Cloud Mac with Local iOS](https://sensepost.com/blog/2022/using-a-cloud-mac-with-a-local-ios-device/)
- [Scaleway Apple Silicon Pricing](https://www.scaleway.com/en/pricing/apple-silicon/)
