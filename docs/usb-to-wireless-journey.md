# USB to Wireless: How We Made It Work

**Date:** April 7, 2026

The full technical story of how iOS device automation went from requiring a USB cable to running wirelessly on the same Wi-Fi network.

## The Starting Point: Everything Over USB

When this project started, the only way to control a physical iPhone was with a cable plugged in. Here's what was happening under the hood.

### The USB Protocol Stack

All iOS-to-Mac communication goes through **usbmuxd** (USB Multiplexer Daemon), a system daemon on macOS at `/System/Library/PrivateFrameworks/MobileDevice.framework/Resources/usbmuxd`. It exposes a Unix domain socket at `/var/run/usbmuxd` (permissions 0666 — any user process can connect).

usbmuxd does two things:
1. Detects iOS devices connected via USB
2. Proxies TCP traffic to any port on the device

The USB protocol itself is not real TCP. It uses a pair of USB bulk endpoints with a custom framing layer that reuses TCP header format. But usbmuxd abstracts this completely — to any host application, it looks like a normal TCP socket.

### How a Tap Command Traveled Over USB

```
agent.mjs (Mac)
  → HTTP POST to localhost:6001
    → Maestro bridge port-forwards to device:22087
      → usbmuxd multiplexes over USB bulk endpoints
        → XCTest runner on iPhone receives the request
          → XCUITest framework executes the tap
            → iOS processes the touch event
```

The full chain:
1. **agent.mjs** sends `POST /touch {x: 200, y: 400}` to `localhost:6001`
2. **Maestro bridge** (Go binary) forwards this through usbmuxd to device port 22087
3. **usbmuxd** encodes the TCP data into USB bulk transfer frames
4. **iPhone's USB stack** receives and decodes the frames
5. **XCTest runner** (HTTP server at port 22087) handles the request
6. **XCUITest framework** calls `element.tap()` at the specified coordinates
7. **iOS** processes the synthetic touch event

### What lockdownd Does

Before any of this works, the Mac must pair with the iPhone through **lockdownd**, the iOS-side daemon listening on TCP port 62078. Pairing requires:
1. User taps "Trust This Computer?" on the iPhone
2. Host and device exchange certificates (stored at `/var/db/lockdown/` on macOS)
3. An SSL/TLS session is established
4. The host calls `StartService` for specific developer services (debugserver, screenshotr, etc.)
5. lockdownd returns a port number where that service is listening

Pairing records contain: DeviceCertificate, HostCertificate, HostID, RootCertificate, RootPrivateKey, HostPrivateKey, SystemBUID, and EscrowBag. These records are what allow the Mac to be "trusted" by the iPhone.

### What the Maestro Bridge Adds

[maestro-ios-device](https://github.com/devicelab-dev/maestro-ios-device) builds on top of the entire Apple stack:

1. **Builds an XCTest runner** in Swift using XCUITest framework
2. **Deploys it** to the iPhone via `xcodebuild build-for-testing`
3. **The runner starts an HTTP server** on device port 22087 with REST endpoints:
   - `POST /touch` — tap at coordinates
   - `POST /inputText` — type text
   - `POST /swipeV2` — swipe gestures
   - `GET /screenshot` — capture screen as PNG
   - `POST /viewHierarchy` — get accessibility tree
   - `POST /launchApp` / `POST /terminateApp` — app lifecycle
4. **Port forwarding** maps `localhost:6001` on the Mac to `device:22087`

The XCTest runner translates HTTP requests into `XCUIApplication` and `XCUIElement` API calls.

### The DeveloperDiskImage Requirement

Many developer services (debugserver, instruments, process control) aren't available until the **DeveloperDiskImage (DDI)** is mounted on the device. This signed disk image adds service definitions. Requirements:
- **Developer Mode** must be enabled (Settings → Privacy & Security → Developer Mode)
- iOS 17+ uses a single DDI per platform (shared across Xcode versions) via the CoreDevice framework

---

## What Changed: iOS 17's Architecture Overhaul

iOS 17 (September 2023) fundamentally changed how developer tools communicate with devices. This is what made wireless practical.

### The Key Shift

Apple replaced the lockdownd/usbmuxd developer service path with a new system:

| | Before iOS 17 | iOS 17+ |
|---|---|---|
| Service discovery | lockdownd (port 62078) | remoted daemon (RemoteXPC) |
| Communication | DTX protocol over usbmuxd | CoreDevice framework over tunnels |
| USB transport | USB bulk endpoints → usbmuxd | USB-Ethernet virtual adapter → IPv6 |
| WiFi transport | lockdownd over TCP (Bonjour) | RemoteXPC tunnel (QUIC or TCP) |
| Protocol | DTX/DVT (Objective-C method dispatch) | HTTP/2 + XPC dictionaries |
| Pairing | lockdownd SSL handshake | SRP-3072 + X25519 + Ed25519 + ChaCha20-Poly1305 |

As Apple stated at WWDC 2023: *"iOS 17 has new debugging infrastructure such that all debugging goes over the network. That's not the same thing as going over Wi-Fi. If you have the device attached via USB, the network requests will go over a virtual network interface running over USB."*

This means **even USB debugging on iOS 17+ uses the tunnel model**. USB and WiFi are now just different transports for the same protocol.

### Timeline of Changes

| Version | Change |
|---------|--------|
| **iOS 11 / Xcode 9** (2017) | First "Connect via network" checkbox. WiFi debugging via lockdownd + Bonjour. Same protocol as USB, different transport. |
| **iOS 16** (2022) | USB-connected iPhones create a non-standard USB-Ethernet adapter with IPv6 link-local address. Introduction of `remoted` daemon. |
| **iOS 17.0** (2023) | Full architectural overhaul. CoreDevice + RemoteXPC replaces lockdownd for developer services. All debugging through tunnels (QUIC or TCP). `xcrun devicectl` replaces many physical device commands. |
| **iOS 17.4** (2024) | CodeDeviceProxy added to lockdownd. Eliminates second pairing dialog. TCP-only tunneling, no special drivers. WiFi accessible via existing lockdownd connection. |

---

## How pymobiledevice3 Makes Wireless Work

[pymobiledevice3](https://github.com/doronz88/pymobiledevice3) is an open-source Python reimplementation of Apple's CoreDevice/RemoteXPC protocol stack. It's what made our wireless setup possible.

### What `pymobiledevice3 remote start-tunnel -t wifi -p tcp` Does

Step by step:

1. **Bonjour/mDNS discovery**: Broadcasts mDNS queries for `_remoted._tcp` services on the local network. The iPhone responds with its IPv6 address and the port where its `remoted` daemon is listening.

2. **RemoteXPC connection**: Connects to the device's `remoted` daemon over HTTP/2. This is Apple's replacement for lockdownd service discovery.

3. **Pairing verification**: Using the pair record from the initial USB trust, authenticates via:
   - **SRP-3072** handshake (Secure Remote Password)
   - **X25519** key exchange
   - **Ed25519** identity verification
   - **ChaCha20-Poly1305** encryption for the transport layer

4. **Tunnel establishment**: Requests a trusted tunnel over `com.apple.internal.dt.coredevice.untrusted.tunnelservice`. With `-p tcp`, creates a TCP tunnel using TLS-PSK (Pre-Shared Key) with MTU 16000. (Without `-p tcp`, uses QUIC over UDP with MTU 1420 — slower for large payloads like screenshots.)

5. **TUN interface creation**: Creates a virtual TUN interface (e.g., `utun5`) on the Mac, establishing an IPv6 point-to-point link. All developer service traffic routes through this interface.

6. **RSD port exposure**: Outputs an RSD (RemoteServiceDiscovery) address and port. Other tools connect via `--rsd HOST PORT`.

### The Key Insight

The protocol above the tunnel is **identical** whether the transport is USB or WiFi:

```
USB:  Mac → USB-Ethernet adapter → IPv6 link-local → tunnel → RemoteXPC → services
WiFi: Mac → Bonjour discovery → IPv6 WiFi → tunnel → RemoteXPC → services
      ↑ different               ↑ identical from here onward
```

pymobiledevice3 reimplements the same protocol Xcode uses internally. The difference is that it's open-source and we can use it from the command line.

### Why TCP, Not QUIC

The `-p tcp` flag matters. TCP tunnels use MTU 16000 bytes. QUIC tunnels use MTU 1420 bytes. For screenshots (500KB-8MB), larger MTU means fewer round trips and significantly faster transfers. We always use `-p tcp`.

---

## How We Set It Up

### One-Time USB Setup

The iPhone must be paired and trusted over USB first. This creates the pairing record that WiFi authentication uses.

```bash
# 1. Enable WiFi connections on the device (stores the setting)
pymobiledevice3 lockdown wifi-connections --state on

# 2. Build and deploy the XCTest runner (requires USB)
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
```

### Wireless Operation

After the one-time setup, no USB cable is needed:

```bash
# Terminal 1: WiFi tunnel (requires sudo for TUN interface creation)
sudo pymobiledevice3 remote start-tunnel -t wifi -p tcp

# Terminal 2: Maestro bridge (start with USB plugged in, unplug after "Ready!")
export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
maestro-ios-device --team-id C924TNC23B --device 00008130-0008249124C1401C
```

On the iPhone:
1. Open MobileAgentCompanion → tap **On-Device**
2. Enter API key in settings
3. Verify green dot ("Runner online port 22087")
4. Type a task or press the Action Button

### What's Actually Happening Wirelessly

```
┌──────────────────────────────────────────────────────────┐
│  Mac (on same WiFi)                                       │
│                                                          │
│  pymobiledevice3 tunnel:                                 │
│    1. Discovers iPhone via Bonjour (_remoted._tcp)        │
│    2. Authenticates via SRP-3072 + X25519 + Ed25519      │
│    3. Establishes TCP tunnel (TLS-PSK, MTU 16000)        │
│    4. Creates TUN interface (utun5) for IPv6 routing     │
│                                                          │
│  Maestro bridge:                                         │
│    1. Connects through tunnel to device:22087             │
│    2. Forwards localhost:6001 → device:22087              │
│    3. Keeps XCTest runner alive                           │
└──────────────────┬───────────────────────────────────────┘
                   │ WiFi (IPv6 through TUN tunnel)
                   │ Protocol: HTTP/2 + RemoteXPC
                   │ Encryption: ChaCha20-Poly1305
┌──────────────────▼───────────────────────────────────────┐
│  iPhone                                                   │
│                                                          │
│  remoted daemon:                                         │
│    - Advertises _remoted._tcp via Bonjour                │
│    - Handles pairing and tunnel establishment            │
│                                                          │
│  XCTest runner (port 22087):                             │
│    - HTTP server translating REST → XCUITest calls       │
│    - Screenshots, taps, types, view hierarchy            │
│                                                          │
│  OnDeviceAgent.swift:                                    │
│    - Calls OpenAI/Gemini API over cellular/WiFi           │
│    - Sends commands to XCTest runner at localhost:22087   │
│    - Updates Dynamic Island via Live Activities           │
└──────────────────────────────────────────────────────────┘
```

---

## Performance: USB vs WiFi

| Operation | USB | WiFi | Notes |
|-----------|-----|------|-------|
| Screenshot | ~100-300ms | ~300-800ms | Large payload, MTU matters |
| Tap | ~50-200ms | ~150-500ms | Small payload |
| Type text | ~100-300ms | ~200-600ms | Medium payload |
| View hierarchy | ~200-500ms | ~500-1500ms | Scales with UI complexity |
| Full agent step | ~1-3s | ~3-8s | Includes LLM call (dominates) |

WiFi overhead comes from: TCP/IP stack (vs USB bulk transfer), WiFi radio latency (~1-5ms), ChaCha20-Poly1305 encryption, and potential WiFi congestion.

In practice, the LLM API call (1-3s) dominates each agent step, so the WiFi overhead on automation commands (~100-300ms extra) is a small fraction of total step time.

---

## Known Limitations

### Enterprise WiFi Blocks Bonjour
University and corporate networks (USC, Yale, etc.) commonly block Bonjour/mDNS multicast traffic. Devices on different VLANs can't discover each other.

**Fix:** Use iPhone's Personal Hotspot. Mac connects to the phone's hotspot, creating a direct network with no multicast filtering.

### No Auto-Reconnect
The pymobiledevice3 tunnel does not auto-reconnect if WiFi drops. If the tunnel dies, you must restart both the tunnel and the Maestro bridge.

**Future fix:** Wrap in a script that monitors and restarts automatically.

### Requires `sudo`
Creating TUN/TAP interfaces is a privileged operation on macOS. The tunnel command requires root.

### Phone Locking
When the iPhone screen locks, iOS may throttle background network activity. The XCTest runner continues running (it's a test process, not a regular app), but response times can degrade. The tunnel itself survives sleep.

### Battery Impact
Maintaining an active WiFi tunnel with polling (companion app polls `/status` every 500ms) increases battery drain. Expect 5-10% extra drain during a 15-minute session compared to USB.

---

## What Made This a Breakthrough

Before wireless, every demo required:
- A USB cable physically connecting the iPhone to the Mac
- The phone sitting next to the laptop
- No way to demo "real-world" usage (nobody uses their phone tethered to a laptop)

After wireless:
- Phone is untethered — hold it, walk around, use it naturally
- Mac can be in another room (or eventually, another city)
- The Action Button experience feels like a real product, not a lab setup
- On-device mode means the phone runs the AI loop itself — the Mac is just infrastructure

The transition from USB to WiFi wasn't just a technical improvement — it changed the product from a developer demo into something that feels like a real personal assistant.

## Sources

- [pymobiledevice3 — Understanding iDevice Protocol Layers](https://github.com/doronz88/pymobiledevice3/blob/master/misc/understanding_idevice_protocol_layers.md)
- [pymobiledevice3 — RemoteXPC.md](https://github.com/doronz88/pymobiledevice3/blob/master/misc/RemoteXPC.md)
- [Understanding usbmux and the iOS lockdown service](https://jon-gabilondo-angulo-7635.medium.com/understanding-usbmux-and-the-ios-lockdown-service-7f2a1dfd07ae)
- [Debugging iOS Applications using CoreDevice (iOS 17+)](https://docs.hex-rays.com/user-guide/debugger/debugger-tutorials/ios_debugging_coredevice)
- [Maestro iOS Driver Architecture](https://deepwiki.com/mobile-dev-inc/Maestro/4.1-ios-driver)
- [libimobiledevice/usbmuxd](https://github.com/libimobiledevice/usbmuxd)
