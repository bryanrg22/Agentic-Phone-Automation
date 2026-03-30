# MobileAgentCompanion — Dynamic Island App

Shows real-time agent progress in the Dynamic Island and Lock Screen while mobile-use runs tasks.

## Xcode Project Setup

### 1. Create the Project
1. Open Xcode → **File → New → Project**
2. Select **iOS → App**
3. Product Name: `MobileAgentCompanion`
4. Team: Select your Apple Developer account
5. Bundle ID: `com.bryanrg.MobileAgentCompanion`
6. Interface: **SwiftUI**
7. Language: **Swift**
8. Save into this `ios/MobileAgentCompanion/` directory

### 2. Add Widget Extension
1. **File → New → Target**
2. Select **Widget Extension**
3. Product Name: `AgentWidgetExtension`
4. Check **"Include Live Activity"**
5. Click **Finish**, then **Activate** the scheme

### 3. Replace Generated Files
Delete the auto-generated Swift files in both targets and add ours instead:

**Main App target — add these files:**
- `App/MobileAgentCompanionApp.swift`
- `App/ContentView.swift`
- `App/AgentService.swift`
- `Shared/AgentActivityAttributes.swift` (check BOTH targets in File Inspector)

**Widget Extension target — add these files:**
- `AgentWidgetExtension/AgentWidgetExtensionBundle.swift`
- `AgentWidgetExtension/AgentWidgetExtensionLiveActivity.swift`
- `Shared/AgentActivityAttributes.swift` (already added, just check this target too)

### 4. Configure Info.plist

**Main App Info.plist — add:**
```xml
<key>NSSupportsLiveActivities</key>
<true/>
```

**App Transport Security — add to main app Info.plist:**
```xml
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```
This allows HTTP connections to your Mac on the local network.

### 5. Signing
1. Select the **MobileAgentCompanion** target → Signing & Capabilities
2. Select your Team and check "Automatically manage signing"
3. Do the same for the **AgentWidgetExtensionExtension** target

### 6. Build & Deploy
1. Connect your iPhone via USB
2. Select your iPhone in the device dropdown
3. **Product → Run** (Cmd+R)
4. First time: Go to **Settings → General → VPN & Device Management** on your phone and trust the developer certificate

## Usage

1. Start the server on your Mac:
   ```bash
   export PATH="/opt/homebrew/opt/openjdk/bin:$PATH:$HOME/.maestro/bin"
   node frontend/server.mjs
   ```

2. Note the Network URL printed (e.g. `http://192.168.1.42:8000`)

3. Open the companion app on your phone

4. Enter the Mac's IP (just the number, e.g. `192.168.1.42`) and tap **Connect**

5. Run a task from the web UI or terminal:
   ```bash
   node agent.mjs "search for USC on maps"
   ```

6. The Dynamic Island will appear showing real-time progress!

## File → Target Membership

| File | Main App | Widget Extension |
|------|----------|-----------------|
| `AgentActivityAttributes.swift` | Yes | Yes |
| `AgentService.swift` | Yes | No |
| `ContentView.swift` | Yes | No |
| `MobileAgentCompanionApp.swift` | Yes | No |
| `AgentWidgetExtensionLiveActivity.swift` | No | Yes |
| `AgentWidgetExtensionBundle.swift` | No | Yes |

## Troubleshooting

| Issue | Fix |
|-------|-----|
| "Untrusted Developer" | Settings → General → VPN & Device Management → Trust |
| "Developer Mode disabled" | Settings → Privacy & Security → Developer Mode → Enable |
| Live Activity doesn't appear | Verify NSSupportsLiveActivities=YES in Info.plist |
| Can't connect to Mac | Both devices must be on same WiFi. Check the IP is correct. |
| HTTP blocked | Add NSAllowsLocalNetworking=YES to App Transport Security |
