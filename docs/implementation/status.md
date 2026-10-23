# Implementation and verification

Last updated: 2026-10-24

## Implemented

- Native SwiftUI windows with an AppKit menu-bar utility lifecycle, explicit left/right-click quick actions, separate channel power/brightness, saved scenes, visible status/errors, local names and versioned settings. Window close keeps Station running; a deliberate Quit awaits cleanup. Login launch is quiet when the user enables it.
- LAN discovery across active interfaces, direct-IP discovery, Base64 device names and validated endpoints.
- Separate Light Bar Pro task-light and RGB-backlight controls. TCP commands use CRLF framing, correlated acknowledgements, bounded deadlines and serialized requests.
- Station UDP token sessions, numeric keepalives, renewal/recovery, stale-response rejection, and recovered RGB/Base64 frame encoders. Unsupported realtime transports fail explicitly.
- Color Play with the eight recovered screen-zone templates, selected-display sampling and per-device zone routing.
- Music Flow using native system audio or microphone input, bounded RMS-level delivery, sensitivity and the 45 recovered palettes.
- The 10 recovered scene presets, channel compatibility validation, white-to-RGB conversion on color-only backlights, saved static scenes and optional static-state restoration.
- Universal app/ZIP builds, Developer ID release signing with Hardened Runtime and secure timestamps, notarization/resume/stapling and atomic verified installation scripts, plus a standalone diagnostic/control CLI.
- Read-only permission status and recovery links, with optional capture access requested only on Start. No view initialization requests capture or writes lights.

## Verified

The current combined suite passed **103 tests**, covering configuration/presets, protocol builders, discovery, loopback TCP/UDP devices, screen sampling, audio-buffer layouts, level smoothing, and capture delivery/teardown, menu channel isolation/action validation, quick controls waiting for background polling, live aggregate device status, and launch/window policy. A further 47 capture/model tests passed under AddressSanitizer; the capture worker also separately verified its 40 synthetic tests. No test requested capture access.

REA 6.7.0 with Ghidra 12.1.4 was executed against the supplied binaries. The [protocol report](../research/device-protocol.md) records native decompile evidence and first-party cross-checks. [Tooling setup](../research/rea-tooling.md) is reproducible.

Version 0.2.0 (3) is built for Apple Silicon and Intel and signed with Developer ID Application, Hardened Runtime and secure timestamps. The expected developer-team designated requirement is compatible across the tested signed updates and contains no build-specific hash. The canonical copy is installed in `/Applications/Yeelight Station.app`; its signature, executable hash and unchanged settings file were verified. The Apple Silicon executable launches; Intel is cross-built, not runtime-tested. The resource self-test loads all 10 scenes, 45 palettes and eight layouts after relocation and from Applications.

The native accessibility tree shows the final installed window, the Light Bar Pro online and consistent 1/1 online counts after fixing aggregate observation. Native clicks and screenshots still failed with `Sky Computer Use native pipe closed before response`; right-click menu interaction and actual login launch remain manual acceptance checks. A normal installed launch and graceful quit were exercised; quit completed in 0.76 seconds. The user confirms adding and controlling the Light Bar Pro. Live screen/system-audio/microphone capture and permission dialogs still require interactive Start in that app.

## Real hardware verification

The supplied light is `yeelight.light.lamp15`, firmware 38, at `192.168.8.173`. After the user moved the Mac onto the same LAN (`192.168.8.179`), the light responded to discovery and both control transports.

Executed checks:

- TCP RGB-backlight scenes and brightness, plus task-light brightness and temperature, were acknowledged and verified by property read-back. The backlight test preserved task-light power, brightness and temperature. Original static settings were restored and verified.
- The app's StationCore library, loaded into the trusted Apple Swift test process, discovered the real light, obtained a UDP session token, and verified authenticated heartbeats.
- The same library sent an eight-second stream of scalar whole-backlight colors at 30%, including renewal across the five-second heartbeat interval. Final RGB/brightness read-back matched the expected frame, task-light state matched its baseline, and original static settings were restored and verified.
- A read-only diagnostic inside the Developer ID signed Applications copy discovered lamp15 and reached TCP 55443. The diagnostic exited cleanly. An earlier signed probe timed out; the successful retry does not establish which privacy/filter decision changed.
- The lamp replies to discovery from UDP **49153**, which exposed and fixed the original fixed-source-port assumption. A regression now accepts dynamic response ports while retaining source-IP/advertised-endpoint validation.

Standalone newly compiled probes had executable-specific network-policy failures while identical code through Apple's interpreter succeeded. This is distinct from protocol correctness. The user reported approving access and subsequently confirmed packaged-app discovery, adding the Light Bar Pro, and controls. Live capture acceptance remains pending. See [local-network diagnostics](../runbooks/local-network.md). No agent changed a privacy rule, firewall or network filter.

The [lamp streaming audit](../research/lamp-streaming.md) establishes why scalar `bg_set_scene` is used for a one-zone lamp15 output; a one-element segmented array has no established whole-bar fill guarantee. Device read-back checks verify protocol state, not an independent visual measurement of every LED.

## Remaining Windows parity

Razer Chroma/Overwolf game integrations, reverse-connect TCP music mode for non-UDP devices, Chroma-only handshakes, concurrent multi-monitor sampling, cloud/account behavior, proprietary FX identifiers, cube/rays mappings and vendor settings import are not implemented. Screen color sampling and music response are new platform-native algorithms, not bit-identical reconstructions.

Developer ID signing, notarization and installation are complete for version 0.2.0 (3). Apple accepted submission `a142fe8a-3676-417d-97c7-e0212a64d57f`; the release app and installed Applications copy have stapled tickets, and the final ZIP was recreated from the stapled release app. Both app copies pass ticket validation, strict signature verification and Gatekeeper assessment with `source=Notarized Developer ID`. The installed ticket was attached without restarting the running app. Packaging scripts additionally passed 26 fixture checks, including replacement races and rollback. The [distribution runbook](../runbooks/distribution.md) documents the setup and release commands. Standalone `stationctl` is signed but is outside the app-only notarization archive. No Windows executable, vendor DLL, icon, font or commercial asset is bundled. Extracted preset numbers and palettes retain their source provenance in the import script and research reports.
