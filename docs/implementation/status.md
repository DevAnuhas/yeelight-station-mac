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
- Universal app/DMG/ZIP builds, Developer ID release signing with Hardened Runtime and secure timestamps, notarization/resume/stapling and atomic verified installation scripts, plus a standalone diagnostic/control CLI.
- Read-only permission status and recovery links, with optional capture access requested only on Start. No view initialization requests capture or writes lights.
- Native Automations for dated/recurring channel actions, local backlight/fallback sleep timers, capability-gated device task-light timers, reported device information and per-channel power-on default saving. See [everyday controls](../product/everyday-light-controls.md).

## Everyday controls (0.3.0)

Automations adds named one-shot, daily, weekday and custom-day channel schedules, with compatible presets or a confirmed static state for turn-on. Device settings provides reported information, a task-light device countdown when advertised, local backlight/fallback countdowns and per-channel default-state saving. Unsupported phone settings remain explicitly managed in the Yeelight app. See [behaviour and limits](../product/everyday-light-controls.md).

The final combined run executed **236 tests: 234 passed, two opt-in visual fixtures skipped, zero failures**. Both visual fixtures are exercised separately. The 35 automation orchestration regressions include persisted claims before uncertain writes, enable/edit races, queued lateness, short sleep/wake, shutdown, same-instant daylight-saving actions, black RGB restoration, timer history and settings preservation. Pure calendar/configuration and documented-command tests cover recurrence, overnight/DST calculations, malformed schedules, required legacy keys and absent new settings. Synthetic native fixtures cover the Automations page, editor and all three device-settings sections at the minimum supported window width. No tests open a real input, request recording access, enable a real schedule or change a physical light.

The scheduler skips actual sleep/wake intervals and long polling gaps, validates current intent before dispatch, and stops sync before applying scheduled controls. Timer/default eligibility comes from advertisement and the [official protocol contract](../research/device-protocol.md#documented-sleep-timers-and-defaults). Physical timer/default execution has not been validated. The reference screenshot's uptime, Wi-Fi and MAC values are not fetched from an undocumented source.

Version 0.3.0 (8) is signed for Apple Silicon and Intel and installed in `/Applications/Yeelight Station.app`. Apple accepted app submission `a8373dc3-a34a-4006-a4d7-39d453727a50`; its stapled ticket, strict signature and Gatekeeper acceptance were verified. Apple also accepted DMG submission `507eb00a-4d7b-4420-b44d-a720d13369c7`; the final app/DMG tickets and Gatekeeper checks pass. Saved settings were unchanged before relaunch, and saved lights/preferences/scenes remained intact afterward. The relocated and installed resource self-tests load all presets. Intel is cross-built, not runtime-tested.

Live native accessibility inspection verified the Automations route and schedule editor. An empty-name save originally triggered recursive SwiftUI accessibility-label resolution and crashed; removing the selectable error text's redundant accessibility override made the same installed-app check show “Give this schedule a name” without crashing. The draft was cancelled and the real schedule list remained empty. The six editor tests passed again after that change. No physical timer or default command was sent during UI verification.

## Artwork update

Version 0.2.1 changes the Dock/Finder icon and repository artwork, with a centered badge row led by the MIT license badge. The banner uses an actual Station window and the expandable README screenshot uses the user's already-running Music Flow interface. No UI reconstruction or generated screenshots are used. The colorful icon is generated; its master, prompts and all ten ICNS representations are retained. The icon is recognizable at 16/32 pixels on light and dark backgrounds. See [artwork sources and reproduction](../runbooks/artwork.md).

The full 103-test suite passed again. App logic, capture and protocol behavior are unchanged. The project now has a standard MIT license; release ZIPs include its notice alongside the signed app. The notice does not modify the accepted app's signed resources or notarization ticket.

## Verified

The version 0.2.4 combined suite passed **167 automated tests**, with one opt-in visual fixture skipped in the default run. That fixture passed separately for the color popover, every app route at two window widths, and the microphone form. All **59 capture tests passed under AddressSanitizer**, including 19 new audio-device cases. Coverage includes configuration/presets, LAN transports, screen/audio processing, delivery/teardown, menu actions, optimistic edits, display/input lifecycle and launch/window policy. No test requested capture access or opened a real audio input.

Displays load on startup, reconcile saved selection and update on topology changes without requesting recording permission. Color Play validates a frozen display choice before device traffic and again before capture, and offers a display submenu. Music Flow instead lists System Audio and named audio inputs; neither Start menu has tooltips. Its system-audio backend chooses a capture surface internally, independently of Color Play. The real Mac's read-only inventory reports two displays; a separate permission-free CoreAudio probe found three input devices and one default.

Named microphones use stable UIDs, resolved again after authorization and verified on the audio unit before and after engine startup. Missing routes fail instead of falling back. The 37 model regressions and 21 menu tests cover candidate source/device changes, exact UID forwarding, stale actions, disconnection, default-route changes, shutdown and inspection without capture. Default-route changes stop default-following capture; explicit devices stay pinned. Source/input preferences remain session-local. Actual recording and hardware routing still require interactive validation.

My Lights uses optimistic brightness, temperature and RGB values with coalesced queued edits and confirmed-state reconciliation. Model regressions include delayed acknowledgements, superseded edits, polling, failure rollback, scene/start/shutdown barriers, per-device critical-command reservations and partial property replies. A successful ACK followed by an omitted property retains the acknowledged value rather than transport cache fallback. Saved scenes and persisted settings use confirmed state. The native color popover retains exact RGB while offering a color field, hue, saturation/brightness sliders, quick colors and validated hex. Header/sidebar padding is reduced while preserving native window chrome.

Version 0.2.2 makes the complete **Connection help** and **About Station** headers clickable, including text and whitespace. A synthetic 560-point SwiftUI host verified that chevron, text and whitespace each toggle once, while the content button fires without collapsing the section. Native buttons retain keyboard semantics and expanded/collapsed accessibility text; actual keyboard-focus and VoiceOver announcements remain manual checks.

REA 6.7.0 with Ghidra 12.1.4 was executed against the supplied binaries. The [protocol report](../research/device-protocol.md) records native decompile evidence and first-party cross-checks. [Tooling setup](../research/rea-tooling.md) is reproducible.

Earlier version 0.2.4 (7) was built for Apple Silicon and Intel and signed with Developer ID Application, Hardened Runtime and secure timestamps. The expected developer-team designated requirement is compatible across the tested signed updates and contains no build-specific hash. That release was installed in `/Applications/Yeelight Station.app`; its signature, executable hash and unchanged settings file were verified. The Apple Silicon executable launches; Intel is cross-built, not runtime-tested. The resource self-test loads all 10 scenes, 45 palettes and eight layouts from the mounted DMG and from Applications.

Apple accepted the app submission `91f849a9-4838-4963-9d15-227d458cea16` and DMG submission `fdf094d9-1239-4542-aa98-38cc58ec98f1`. The release and installed apps have valid stapled tickets, strict signature verification and Gatekeeper acceptance with `source=Notarized Developer ID`. The DMG container also passes signature, image, stapled-ticket and Gatekeeper checks. Its mounted app passes strict signature verification and matches the installed executable. The image includes the MIT `License.txt`, Applications link, Retina background and Finder layout. The 0.2.2 native Finder screenshot verified the unchanged installer layout fits when path/status bars are visible. The alternate ZIP was recreated from the stapled app.

The update followed a graceful shutdown and preserved saved lights and settings byte-for-byte before relaunch. Existing app packaging scripts passed 26 fixture checks, including replacement races and rollback. All 16 DMG fixtures pass, including mounted-only signature rejection, unchanged output on failure, and protection against Finder flags on signed app contents. Both new regressions were verified against deliberately broken temporary copies. The [distribution runbook](../runbooks/distribution.md) documents app and DMG builds, notarization/resume, installation and publication as a regular Latest GitHub release. Standalone `stationctl` is signed but is outside the app-only notarization archive.

The native accessibility tree shows the 0.2.3 installed window, Light Bar Pro online, consistent 1/1 counts and the new RGB color button. A native window screenshot verified tighter header spacing. Earlier native input failed with `Sky Computer Use native pipe closed before response`; opening selectors, right-click menu interaction and actual login launch remain manual acceptance checks. Normal installed launch and graceful quit were exercised. The user confirms adding and controlling the Light Bar Pro on earlier builds. Live multi-display screen/system-audio/microphone capture and permission dialogs still require interactive Start in the installed app.

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

No Windows executable, vendor DLL, icon, font or commercial asset is bundled. Extracted preset numbers and palettes retain their source provenance in the import script and research reports.
