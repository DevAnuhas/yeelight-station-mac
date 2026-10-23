# lamp15 streaming payload audit

Research date: 2026-10-23. Scope: one-zone Color Play/Music Flow output for Monitor Light Bar Pro (`lamp15`). Research only; application and transport were not edited and no device commands were sent. See the [protocol report](device-protocol.md) for transport/session framing and artifact identities, and [REA setup](rea-tooling.md) for tooling.

## Decision for the current app

**Prefer scalar `bg_set_scene` for lamp15's current one-zone RGB-backlight output, before `set_segment_rgb`. Do not guess six segments or any other physical count.** The user reports that their lamp15 firmware 38 advertises `bg_set_scene`, `bg_set_rgb`, and `set_segment_rgb`, but not `update_leds`; TCP BG scene/brightness and main CT/brightness were verified and restored by the parent task. That is session-reported hardware evidence, not a hardware test performed by this audit. UDP color-frame behavior remains untested.

The current Swift call supplies `[frame[index]]` in `Sources/YeelightStation/StationModel.swift`, and `RealtimeCommands.frame` in `Sources/StationCore/UDPRealtime.swift` chooses `set_segment_rgb` whenever advertised. That turns one **logical zone color** into one **segmented payload entry**. The recovered implementation instead constructs its segmented array from device length/mapping metadata. No inspected first-party source or binary establishes that a one-element segment array broadcasts across lamp15. Therefore the current encoder has no evidence-backed whole-backlight coverage guarantee. [B1, B2, B5]

The narrow suggested change is: for `model == "lamp15"`, background channel, and this scalar one-zone assignment, select advertised `bg_set_scene` first; use its existing scalar `bg_set_rgb` fallback if necessary. Preserve rejection of main-channel RGB on lamps. Keep ordinary session/token handling. A representative scalar frame is `bg_set_scene ["color", RGB, brightness, 0, "sudden"]`; duration precedes effect in this UDP extension. This recommendation is a conservative application policy for the current scalar input, **not** a claim that Station always forces lamps to scalar commands. [B4, P1, P2]

## What original Station actually chooses

The GUI `YeelightStation.exe` connects through `YeeDaemonConnectLib.dll`. The relevant capture output chooser is in **`YeeDesktopCapturer.exe`**, not the GUI's ordinary static-color handler. Its embedded source/log names identify `common/capturecommanddata.cpp` and `CaptureCommandData::sendCommandMsg`; the same executable contains `audio/audiodataconverter.cpp`. [B1]

At capturer RVA **`0x277c0`** (`CaptureCommandData::sendCommandMsg`, reconstructed name), the recovered flow is:

1. Require a nonempty color map, a true per-device byte at `YeelightInfo + 0xb9`, and power on for the selected light type. The `+0xb9` byte's precise public name was not established; it must not be confused with an advertised method or the lamp-family bit. Getter RVA `0x295e0` reads it. [B1, B2]
2. Obtain the output-array count from device metadata. For the ordinary non-cube/non-rays branch relevant to lamp15, getter **`0x296a0`** computes `ceil(length / max(1, repeat))` from fields `+0x98` and `+0xa0`. **If count is zero, use the scalar helper `0x27c30` immediately.** [B1, B2]
3. Build an array of that count, looking up each mapped index and filling unmapped/zero RGB values with integer `1`. This is explicit spatial-array construction; the number of upstream logical colors alone is not its size. [B1, instructions `0x27880–0x27907`]
4. If device flag **`0x100`** is present, call `YeeDaemonConnectLib::setSegmentRgbColorEX(did, array, count, repeat)` at **`0x27946`**. For the ordinary lamp branch, repeat comes from **`0x296e0`**, field `+0xa0`. Otherwise, if flag **`0x4`** is present, call `setSegmentRgbColor(did, array, count)` at **`0x27a49`**. If neither flag is present, use scalar helper **`0x27c30`**. [B1, B2]
5. Scalar helper **`0x27c30`** takes mapped index zero's RGB and brightness, obtains actual light type through **`0x29490`**, and calls `SetSceneRgbColor` at **`0x27cdb`**. It supplies effect enum `2` and a duration clamped to at least 50; this is an original presentation choice, not evidence that duration zero is invalid. [B1, B2]

The capture-frame dispatcher at **`0x1f6c0`** calls this chooser at **`0x1f9c1`**. The evidence establishes the shared capture output decision and the audio converter's additional scalar-scene call at **`0x1388d`**; it does not claim to reconstruct every GUI signal between the named product pages and these functions. [B1, B3]

**There is no unconditional `lamp → scalar before all segmented methods` rule in this capture chooser.** If a lamp has a positive recovered segment count and flag `0x4`, it can take the legacy segment branch. The scalar-first recommendation above is justified by the current app's scalar input and missing length/mapping reconstruction, not an invented original lamp-only priority rule. [B1, B2]

Station's separate Chroma broadcast chooser in `YeeDaemonService.exe` supplies useful corroboration, with a distinct policy: **without `update_leds`, a uniform expanded array collapses to a scalar scene** at RVAs `0x105b4–0x105e0`, `0x109a4–0x10ad6`; a nonuniform legacy array goes to `SetSegmentRgbColor` at `0x10bd8`. With flag `0x100`, it takes EX and passes explicit repetition at `0x10999`. Do not attribute that uniform-color optimization to the capture chooser, which does not contain it. [B6]

## Lamp type, capability flags, and fallback boundaries

`YeeDaemonLib::ParseYeelightDeviceAndLightType`, RVA **`0x1e960`**, combines flags rather than choosing one mutually exclusive model type: advertised `set_segment_rgb` adds `0x4`; `update_leds` adds `0x108`; a trimmed, lowercased model beginning `lamp` adds `0x2`. These flags coexist. The separate channel/light-type result marks BG availability from `bg_` support. [Protocol evidence D8; existing `.analysis/protocol/rea-decompile-capabilities.json`]

Capturer getter **`0x29490`** converts the lamp bit to light-type enum **2**: `((deviceFlags >> 1) & 1) * 2`. Thus the original scalar helper sends BG for lamp15 even though segment methods are endpoint-wide and unprefixed. `YeeDaemonLib` scene builder **`0x1bf00`** rejects a lamp color scene when light type is not 2; BG-prefix helper **`0x1e6b0`** turns `set_scene` into `bg_set_scene`. [B2, B4; protocol D8]

The supported-method fallback observed in the capture chooser is `update_leds flag → set_segment_rgb flag → scalar scene`, conditional on usable metadata and per-device state. It is not a retry chain that sends a segmented packet, waits for failure, and automatically retries a scene. The inspected scene builder does not establish an automatic `bg_set_scene → bg_set_rgb` retry either; the latter is a supported-method fallback the native app already implements and the first-party connector separately demonstrates. [B1, B4, P1, P2]

## EX repetition and `strip_length`

The segmented export chain is unambiguous:

- `YeeDaemonLib.dll` export **`0x1f1b0`** (`SendYeeRequest_SetSegmentRgbColor`) calls builder **`0x259d0`**, which emits the supplied integer-array entries as `set_segment_rgb`. It does not expand a single RGB into a whole-device fill. [B5; protocol D5]
- Pointer/count/repeat export **`0x1f330`** (`SendYeeRequest_SetSegmentRgbColorEX`) calls **`0x26040`**. That helper creates `(RGB, repeat)` pairs for each supplied RGB. List overload **`0x1f270`** accepts such pairs directly. [B5]
- Builder **`0x25cc0`** appends the **R, G, B bytes repeatedly for each pair's positive repeat count**, then Base64-encodes the complete byte array. The wire params are `[base64]`. There is no wire `repeat` parameter and no single-color-fill marker. Exact append loop: **`0x25e51–0x25e94`**, Base64: **`0x25eac`**. [B5; protocol D6]

For the ordinary capture branch the emitted RGB-triple count is therefore `ceil(length / max(1, repeat)) * repeat` for positive repeat. This proves the original's explicit array sizing and replication. It does **not** prove every firmware requires exactly `strip_length` triples, what a short array does to unaddressed LEDs, or any physical LED count for lamp15. Repeating one RGB once merely emits three raw RGB bytes before Base64; it is not evidence of a whole-strip fill.

The daemon's `get_prop` response reader **`0x14e30`** parses a returned nonnegative length into **`YeelightInfo + 0x98`** through setter **`0x35b0`** and logs it as `strip_length` (`0x150e8`). The runtime/cache key elsewhere is misspelled `strip_lenth`; see the protocol report. The per-color repeat field `+0xa0` is separate from length. The supplied binaries do not justify treating the logical-zone count, mapping selection, repeat, and length as interchangeable. [B7, B2]

At audit entry, native `LightDevice.segmentCount` derives a count from `properties["strip_length"]`, defaulting to one, while `LightConnection.properties()` does not request `strip_length`; the actual app frame also contains only one color. Merely querying the property would not repair selection or construct the original expanded frame. For this lamp15 scalar task, use the advertised scalar BG command instead of introducing guessed length or repetition.

## First-party source corroboration

The official Yeelight connector, pinned at commit **`769a616b9012877baf7fa3df426b38ca6697a167`**, selects its BG command type from advertised methods: `bg_set_rgb`, then `bg_set_scene` when available. Its type-2 builder sends scalar **`bg_set_scene ["color",rgb,brightness,duration,effect]`**, with token and CRLF. Its type-1 builder uses scalar `bg_set_rgb`; it also has a first-call power-on behavior. These are connector-specific type codes, not Station's later flag values. [P1, P2]

That 2021 source has no `set_segment_rgb`, `update_leds`, or spatial-repeat implementation. Its `lamp15` branch selects an icon, not a physical count or an unconditional output type. It proves the scalar BG protocol path and preserves the evidence boundary on newer segmented behavior. [P3]

## Evidence and reproduction

Addresses above are **RVAs**. Add image base `0x400000` for the EXEs or `0x10000000` for the DLL to obtain the preferred virtual address accepted by REA. Ghidra function names are reconstructed unless an imported/exported symbol supplies the name. No Windows executable was run.

Binary identities:

- `YeeDesktopCapturer.exe`: SHA-256 `da36d42fbc6454e9a0849cf73c912ad94b3f972bfda5f9470bae6bb58a2e6bdf`.
- `YeeDaemonService.exe`: SHA-256 `556be9164d22e43c771d5de4bc19f5b94f8d812bba150b2fe83cdf3aba32b407`.
- `YeelightStation.exe`: SHA-256 `14d3e2794b0a40b26bf199cd0872e4fce0b24714678a9a2ea499a2afbb07f949`.
- Daemon/Common/Connect DLL hashes are in the [protocol report](device-protocol.md#evidence-and-address-convention).

Local raw evidence is retained under ignored `.analysis/lamp-streaming/`; the helper `rea_session.py` uses REA's stdio MCP to keep one Ghidra session open, without mutating binaries. Raw instruction inventories use the existing `scripts/research/inspect_pe.py`.

- **B1:** `capturer-output-selector.json`, `ev_1b265446ea3e99cffc7bee1800ec7cfb484b27ccc95ee9d9e3830c57764add0d`; complete decompiles of capture chooser `0x4277c0`, scalar helper `0x427c30`, and audio converter `0x412860`.
- **B2:** `capturer-selector-helpers.json`, `ev_50d0026cdb5d39b046b7a31b33377d0c9131bd066392c02896e9b3fcfaef3194`; type/count/repeat/flag getters and scalar helper. `capturer-disassembly.txt` corroborates the exact branches/calls.
- **B3:** `capturer-frame-dispatch.json`, dispatcher `0x41f6c0`; `capturer-selector-incoming.json`, `ev_ff3373b6d17044b4cd9270307702598555d35444b48e9dc1ea5d2c0739d36665`, caller `0x41f9c1`.
- **B4:** `daemon-scene-length.json`, scene export wrapper `0x1001f0c0`, request builder `0x10025270`, UDP lamp guard/scene builder `0x1001bf00`; existing protocol D8 identifies BG-prefix behavior. CommonLib compact-JSON/CRLF serializer is protocol D2; it does not supply a separate lamp-selection rule.
- **B5:** `daemon-export-builders.json`, exports `0x1001f1b0`, `0x1001f270`, `0x1001f330` and expansion `0x10026040`; `daemon-scene-length.json` includes legacy builder `0x100259d0`; existing protocol D6 and `rea-decompile-update-leds.json` identify byte repetition/Base64.
- **B6:** `service-callers.json`, Chroma chooser `0x40ff90`; `service-selector-helpers.json`, flag/type/count/repeat getters. `service-disassembly.txt` corroborates uniform-array/scalar branches and export calls.
- **B7:** `daemon-scene-length.json`, get-prop reader `0x10014e30`; `model-setters.asm`, setter `0x35b0`; `model-getters.asm`, length getter `0x2f10`.
- **P1:** [Official connector capability selection, lines 1657–1682](https://github.com/Yeelight/Yeelight-Chroma-Connector/blob/769a616b9012877baf7fa3df426b38ca6697a167/ChromaBroadcastSampleApplication/ChromaBroadcastSampleApplicationDlg.cpp#L1657-L1682).
- **P2:** [Official scalar scene/RGB builder, lines 304–369](https://github.com/Yeelight/Yeelight-Chroma-Connector/blob/769a616b9012877baf7fa3df426b38ca6697a167/ChromaBroadcastSampleApplication/CUdpLight.cpp#L304-L369).
- **P3:** [Official lamp15 icon selection, lines 845–870](https://github.com/Yeelight/Yeelight-Chroma-Connector/blob/769a616b9012877baf7fa3df426b38ca6697a167/ChromaBroadcastSampleApplication/ChromaBroadcastSampleApplicationDlg.cpp#L845-L870). The local first-party source audit and hashes are `.analysis/lamp-streaming/firstparty.md` and `firstparty-downloads/source-audit.json`.

Minimal independent decompile commands:

```sh
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDesktopCapturer.exe" 0x4277c0 --provider ghidra --json
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDesktopCapturer.exe" 0x427c30 --provider ghidra --json
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDaemonService.exe" 0x40ff90 --provider ghidra --json
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDaemonLib.dll" 0x10026040 --provider ghidra --json
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDaemonLib.dll" 0x10025cc0 --provider ghidra --json
```
