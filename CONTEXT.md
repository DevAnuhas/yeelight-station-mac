# Current context

Last updated: 2026-10-24

Native SwiftUI macOS port of Yeelight Station 1.5.0.31025, targeting Monitor Light Bar Pro (`lamp15`). REA 6.7.0 and Ghidra 12.1.4 were built locally and used to corroborate device protocol builders. Windows executables were extracted and statically analyzed, never executed.

A universal Apple Silicon/Intel application, capture, transport, presets and automated tests exist. Packaging and resource relocation checks pass. The user confirms that the packaged app discovers, adds and controls the Light Bar Pro. See [status](docs/implementation/status.md) and [documentation map](docs/README.md).

The Mac is now on the light’s LAN (`192.168.8.179`). Real lamp15 firmware 38 accepted independent channel controls, plus StationCore discovery, UDP token/heartbeat and an eight-second RGB stream loaded through the trusted Swift test process; original static state was verified restored. Standalone compiled probes showed per-executable network-policy blocking. The user approved access and confirmed that app discovery and controls work. Live capture acceptance remains pending. See [network diagnostics](docs/runbooks/local-network.md).

Razer/Overwolf, proprietary FX, cube/rays mapping and concurrent multi-monitor capture are not implemented. The app clearly identifies preview mode and unsupported integrations.

Current priority: daily-use experience. Version 0.2.3 (6) is Developer ID signed and installed in `/Applications`. Displays load automatically, Start validates selection, and both display-based sync menu actions offer monitor choices. My Lights uses optimistic coalesced adjustments with confirmed-state reconciliation, a native color popover and tighter header spacing. All 134 automated tests pass; the opt-in visual fixture passed separately across every route at two sizes. The app and DMG are Apple-notarized, stapled and Gatekeeper-accepted; installation preserved settings. Native input still fails, so live multi-display capture, right-click and login acceptance remain manual. All release titles use “Yeelight Station.” See [verification](docs/implementation/status.md) and [release workflow](docs/runbooks/distribution.md).

The artwork update replaces the small dark Dock icon with a colorful light-bar mark and uses actual Station/Music Flow screenshots in the README. Centered badges begin with MIT; the repository and release archive include the MIT notice. [Artwork guide](docs/runbooks/artwork.md) records assets and reproduction.
