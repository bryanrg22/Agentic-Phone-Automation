# One-Device Transition Research

This note captures the feasibility analysis for moving from a two-device setup (iPhone + Mac control plane) toward a one-device ownership UX.

## Goal

Make the iPhone the primary agent runtime ("the phone is breathing"), while minimizing user dependence on owning/configuring a separate MacBook.

## Current Architecture Reality

- On-device agent logic can run on iPhone (LLM calls, planning, memory, status updates).
- Cross-app control still depends on developer automation channels (XCTest/WDA/bridge).
- In the current implementation, control calls target a runner endpoint and fail if that channel is unavailable.

## Deep Research Summary

## 1) Physical real-device automation exists and is mature

- Real iPhone automation with XCTest/WebDriverAgent/Appium is established.
- Typical setup requires trust + developer mode + provisioning/signing + runner lifecycle.

Reference:
- Appium XCUITest real-device preparation:
  - https://appium.github.io/appium-xcuitest-driver/latest/getting-started/device-setup/

## 2) Wireless operation exists

- Appium supports attaching to a running WDA endpoint at a reachable IP.
- This enables real-device control without active USB during execution when environment is configured correctly.

Reference:
- Attach to running WDA:
  - https://appium.github.io/appium-xcuitest-driver/latest/guides/attach-to-running-wda/

## 3) Remote endpoint orchestration exists (industry + self-hosted)

- Device clouds and self-hosted farms expose remote endpoints for real-device automation.
- This validates the "phone hits remote control API" model.

References:
- Sauce Labs real device Appium:
  - https://docs.saucelabs.com/mobile-apps/automated-testing/appium/real-devices/
- Appium Device Farm:
  - https://devicefarm.org/setup/

## 4) Why full stock-iOS hostless control is still blocked

- Third-party app sandboxing prevents unrestricted system-wide tap/type/process control.
- Public iOS APIs do not provide free-form cross-app automation primitives equivalent to developer test channels.
- No reliable stock-iOS loophole found that removes the control-plane requirement.

## 5) MCP and trigger implications

- MCP can improve tool abstraction/orchestration but does not bypass iOS permission boundaries.
- Reactive triggers are feasible through:
  - Shortcuts/App Intents for user-mediated triggers,
  - backend/webhook triggers for external channels (email/services),
  - explicit consent flows for risky automation.

## Recommended Transition Strategy

## Phase A: Phone-first + remote worker (now)

- Keep planning/memory/HITL on iPhone.
- Move control-plane execution behind an authenticated remote worker API.
- Support two worker backends:
  1. Home Mac worker
  2. Hosted managed worker (subscription model)

Required API surface:
- `/health`
- `/execute`
- `/screenshot`
- `/viewHierarchy`
- `/reconnect`

Operational requirements:
- heartbeat
- auto-restart runner/tunnel
- retries/timeouts
- signed auth + replay protection

## Phase B: Reduce manual setup burden

- Add "Shortcut Copilot":
  - detect repeated tasks
  - ask user consent
  - scaffold automation path with minimal manual steps
- Add trigger templates (sender/keyword/time/location) and policy tiers (auto-run vs ask-first).

## Phase C: Max autonomy within platform limits

- Continue minimizing host dependency while retaining reliability.
- Keep architecture compatible with future Apple platform changes that might expand local automation capabilities.

## Positioning

This project is not trying to reinvent generic QA infrastructure. It is building a personal, phone-first iOS agent UX on top of proven automation rails, with a clear path from two-device setup to one-device ownership experience.
