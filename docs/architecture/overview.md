# Architecture

Station is a native SwiftUI macOS application, with no Windows compatibility layer and no server dependency. The target device for the initial port is the Monitor Light Bar Pro (`lamp15`).

## Boundaries

- `StationCore` owns discovery, device descriptions, acknowledged TCP control, authenticated UDP realtime sessions, presets, and versioned local settings. Each light has serialized socket workers; capture callbacks never block on network I/O. The [protocol report](../research/device-protocol.md) is the source for recovered binary behavior and unresolved protocol questions.
- `StationCapture` owns ScreenCaptureKit screen and system-audio capture, AVAudioEngine microphone input, bounded latest-frame delivery, screen-zone color sampling, and audio RMS envelopes. It requests access only when the corresponding capture starts. See [capture](../research/macos-capture.md).
- `YeelightStation` owns the SwiftUI window, native AppKit status menu, routing, scene execution, capture/transport coordination, and static-state restoration. The main task light and RGB backlight have separate controls; realtime RGB routing defaults to the backlight on a light bar.
- `stationctl` offers reproducible discovery, read-only property probes, and acknowledged controls without the GUI.

## State and lifecycle

Settings are versioned JSON in `~/Library/Application Support/YeelightStationMac/station.json`, saved atomically. Unknown versions and malformed values are rejected without overwriting the original file. `--demo` is a visibly labeled preview that neither persists settings nor sends device commands.

A sync run snapshots selected channels, starts UDP sessions and capture, then routes the latest colors to selected zones. Pending samples replace older samples rather than accumulating tasks. Stop invalidates delivery, awaits capture and output teardown, stops session heartbeats, and optionally restores static color, brightness, and power. Previous dynamic color flows and device FX cannot currently be restored. Quit follows the same cleanup path.

Closing a window leaves the process and deliberately started sync running in the menu bar. Daily-use permissions are read from macOS rather than persisted as assumed grants. Release builds retain one Developer ID identity and installation path; see [distribution](../runbooks/distribution.md).

Ordinary TCP controls wait for correlated acknowledgements and surface device errors. Realtime frames do not require individual acknowledgements. Session/heartbeat responses establish freshness; unsupported channels and methods fail explicitly.

Brightness, temperature and color adjustments update the visible model immediately. One serialized worker coalesces queued changes by device, channel and property while keeping the in-flight command immutable. Confirmed properties are stored separately from desired values; fresh property replies merge underneath pending edits, and rejected edits revert to confirmed state. The app requests observed-only properties so transport cache fallback cannot overwrite an acknowledged value. Scenes, capture startup and shutdown form barriers around accepted adjustments; saved scenes and persisted device state use confirmed values.

Startup and display-topology notifications enumerate Core Graphics displays without requesting recording permission. A missing saved display is reconciled to an available choice. Color Play freezes the selected display, refreshes availability before device work and before capture, and rejects a stale choice rather than silently switching it. Disconnecting an active capture display stops sync through normal cleanup.

Music Flow selects System Audio or a named audio input. CoreAudio inventory and topology observers read input channels, stable device UIDs and the default route without opening an input or requesting permission. Start freezes and revalidates the source and resolved UID, then selects and verifies that microphone on the engine's audio unit. Explicit inputs remain pinned across default-route changes; removed inputs and changed default routes stop capture instead of silently switching microphones. Source/input preferences are session-local. System audio chooses its ScreenCaptureKit backing display internally and does not use Color Play's selection. Both Start menus omit tooltips.

## Platform boundaries

The Windows app's Qt UI, WASAPI/desktop capture, daemon processes, Razer Chroma DLL and Overwolf runtime are not macOS binaries. SwiftUI, ScreenCaptureKit and AVAudioEngine replace the native UI/capture/service functions. Chroma/Overwolf game integration, cube/rays segment mapping, proprietary FX identifiers, cloud account behavior and Windows settings/database import remain unported.

The screen sampler and audio envelope are new implementations guided by recovered configuration. They are not proven bit-identical reconstructions of the Windows capture algorithms. Current screen routing chooses one display at a time; original concurrent multi-monitor capture remains a parity gap.

See [verification status](../implementation/status.md) before making compatibility claims.
