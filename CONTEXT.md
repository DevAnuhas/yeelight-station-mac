# Current context

Last updated: 2026-10-24

Native SwiftUI macOS port of Yeelight Station 1.5.0.31025, targeting Monitor Light Bar Pro (`lamp15`). REA 6.7.0 and Ghidra 12.1.4 were built locally and used to corroborate device protocol builders. Windows executables were extracted and statically analyzed, never executed.

A universal Apple Silicon/Intel application, capture, transport, presets and automated tests exist. Packaging and resource relocation checks pass. The user confirms that the packaged app discovers, adds and controls the Light Bar Pro. See [status](docs/implementation/status.md) and [documentation map](docs/README.md).

The Mac is now on the light’s LAN (`192.168.8.179`). Real lamp15 firmware 38 accepted independent channel controls, plus StationCore discovery, UDP token/heartbeat and an eight-second RGB stream loaded through the trusted Swift test process; original static state was verified restored. Standalone compiled probes showed per-executable network-policy blocking. The user approved access and confirmed that app discovery and controls work. Live capture acceptance remains pending. See [network diagnostics](docs/runbooks/local-network.md).

Razer/Overwolf, proprietary FX, cube/rays mapping and concurrent multi-monitor capture are not implemented. The app clearly identifies preview mode and unsupported integrations.

Current priority: daily-use experience. Version 0.3.1 (9) is Developer ID signed, Apple-notarized and installed in `/Applications`; the DMG is notarized and stapled too. The app follows macOS appearance, uses the supplied Yeelight sidebar logo plus a generated white-lettered dark variant, and has ellipsis-only context triggers and connected monitor artwork. The menu bar now offers all ten built-in scenes with routing compatibility checks, plus saved scenes. All 245 automated tests pass, both visual fixtures pass separately and both logo bundles load after relocation. Live native inspection verified the sidebar, monitor and light menu; cached offscreen sidebar rows remain an unreliable visual capture. Settings are preserved. Physical timer/default behaviour and live recording/routing remain manually unverified. See [artwork](docs/runbooks/artwork.md), [verification](docs/implementation/status.md), [everyday controls](docs/product/everyday-light-controls.md) and [distribution](docs/runbooks/distribution.md).

The artwork update replaces the small dark Dock icon with a colorful light-bar mark and uses actual Station/Music Flow screenshots in the README. Centered badges begin with MIT; the repository and release archive include the MIT notice. [Artwork guide](docs/runbooks/artwork.md) records assets and reproduction.
