# Current context

Last updated: 2026-10-24

Native SwiftUI macOS port of Yeelight Station 1.5.0.31025, targeting Monitor Light Bar Pro (`lamp15`). REA 6.7.0 and Ghidra 12.1.4 were built locally and used to corroborate device protocol builders. Windows executables were extracted and statically analyzed, never executed.

A universal Apple Silicon/Intel application, capture, transport, presets and automated tests exist. Packaging and resource relocation checks pass. The user confirms that the packaged app discovers, adds and controls the Light Bar Pro. See [status](docs/implementation/status.md) and [documentation map](docs/README.md).

The Mac is now on the light’s LAN (`192.168.8.179`). Real lamp15 firmware 38 accepted independent channel controls, plus StationCore discovery, UDP token/heartbeat and an eight-second RGB stream loaded through the trusted Swift test process; original static state was verified restored. Standalone compiled probes showed per-executable network-policy blocking. The user approved access and confirmed that app discovery and controls work. Live capture acceptance remains pending. See [network diagnostics](docs/runbooks/local-network.md).

Razer/Overwolf, proprietary FX, cube/rays mapping and concurrent multi-monitor capture are not implemented. The app clearly identifies preview mode and unsupported integrations.

Current priority: daily-use experience. Version 0.2.0 (3) is Developer ID signed and installed in `/Applications`, with native menu-bar quick actions, background/window lifecycle and read-only permission guidance. All 103 tests pass; the installed identity discovers the real light and reaches its control port. Apple accepted notarization; release and installed copies are stapled, signature-validated and Gatekeeper-accepted. Native click automation remains unavailable, so right-click/login interaction acceptance is manual. See [release workflow](docs/runbooks/distribution.md).
