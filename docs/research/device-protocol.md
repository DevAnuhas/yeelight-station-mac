# Yeelight Station device protocol research

Research date: 2026-10-23. Target: the extracted Windows build under `.analysis/windows-app` (PE timestamp 2023-10-26). This is static reverse-engineering evidence, cross-checked with first-party protocol documents. No lamp was contacted and no device compatibility claim below means a hardware test passed.

## Findings that affect a macOS port

Station uses both ordinary Yeelight LAN TCP and a token-bearing UDP protocol on **55444**. Public TCP/music-mode support alone does not reproduce Station's realtime path. The UDP protocol is partly documented by Yeelight; segmented `update_leds` encoding was recovered from the binary. Device features are inferred from discovery's advertised method list and model families, rather than a complete model whitelist in the daemon. [D1–D9, P1, P2]

The recovered high-throughput representation is **JSON containing Base64 RGB bytes**, not an unframed stream of raw RGB datagrams. Legacy segmented commands contain JSON integer arrays. Treat `set_segment_rgb`, `update_leds`, public `set_music`, and `update_music_data` as distinct capabilities. [D4–D7]

## Evidence and address convention

All binary addresses in this document are **RVAs**. For these DLLs, preferred virtual address = `0x10000000 + RVA`; runtime ASLR addresses can differ. File offsets are stated explicitly where used. Pseudocode is a reconstruction, not original source. The conclusions were checked against x86 instructions, imported Qt APIs, and literal bytes.

| Artifact | Bytes | SHA-256 |
| --- | ---: | --- |
| `YeeDaemonLib.dll` | 283624 | `ba67486fef12531a2da5cdf065d665783ae037d3ae25e15f1223b33e4e752cb8` |
| `YeeCommonLib.dll` | 394728 | `dae03fd3cffeab2886240dcbaa3feff2a13be1d65c715b9250d07e5008605c80` |
| `YeeDaemonConnectLib.dll` | 118760 | `f9795c19d0a2bffc68ae5e96570ef79e116a575f05ed23efa5e8ef2407a17ff7` |

Local evidence is retained under ignored `.analysis/protocol/`. Durable inspection helper: [`scripts/research/inspect_pe.py`](../../scripts/research/inspect_pe.py). REA setup and wrapper: [`rea-tooling.md`](rea-tooling.md).

| ID | Primary evidence |
| --- | --- |
| D1 | `YeeDaemonLib.dll`: discovery request literal RVA `0x2f778`, file `0x2eb78`; multicast address RVA `0x2f560`; UDP destination 1982 at `0x129b7`, send call `0x129c5` |
| D2 | `YeeCommonLib.dll`: JSON serializer RVA `0x296c0`, compact `QJsonDocument::toJson(1)` at `0x29710`, append at `0x29724`; appended literal RVA `0x37060` is bytes `0d 0a 00` |
| D3 | `YeeDaemonLib.dll`: UDP session selection `0x179a0–0x17a58`; creation builder `0x17610–0x178f9`; token parser `0x1a705–0x1a8d4` |
| D4 | `YeeDaemonLib.dll`: general UDP command builder `0x1ca80–0x1ce90`; top-level token insertion `0x1cd51–0x1cd84`; UDP send serializer `0x1d0cb`, destination push `0x1d26e`, send call `0x1d280` |
| D5 | `YeeDaemonLib.dll`: legacy segmented export `0x1f1b0`, builder `0x259d0`, RGB integer loop `0x25b60–0x25b8a` |
| D6 | `YeeDaemonLib.dll`: segmented EX list export `0x1f270`, pointer/count/repeat export `0x1f330`; `update_leds` builder `0x25cc0`, RGB append loop `0x25e51–0x25e94`, Base64 call `0x25eac`; EX expansion `0x26040–0x2610d` |
| D7 | `YeeDaemonLib.dll`: RGB extraction helper `0x28f0–0x291c`; supported request method list initializer `0x1150–0x1383` |
| D8 | `YeeDaemonLib.dll`: capability classifier export `ParseYeelightDeviceAndLightType` at `0x1e960–0x1ec52`; UDP admission `0x1a020–0x1a103`; BG command prefix helper `0x1e6b0–0x1e7d1`; lamp color rejection `0x1c015–0x1c063` |
| D9 | `YeeDaemonLib.dll`: keepalive builder `0x1c860–0x1ca7f`; maintenance `0x18400–0x18929`; send gating `0x19f50–0x19fd8`; monotonically increasing request IDs `0x100e0–0x100f7` |
| D10 | Installer `localcache/yeelocalcache.db3`: REA SQLite evidence ID `ev_38746ce177fe3555e29f98e88ea4f85d5dd1bdcce2e0345377719c151a271ae9`, SHA-256 `b606f1d29270a272d4eb7d7926fe3b6e3e23a9fb6934c0455de9fd1230f32322` |
| D11 | `YeeDaemonLib.dll`: activate-FX builder `0x242f0–0x24914`; mode/speed/percent/palatte fields `0x24559`, `0x245be`, `0x2461d`, `0x246e4`; deactivate-FX builder `0x24950–0x24bdb` |
| P1 | [Yeelight WiFi Light Inter-Operation Specification](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf), especially §§3.1, 4.1 and Table 4-1 |
| P2 | [Yeelight UDP R2 specification](https://github.com/Yeelight/Yeelight-Chroma-Connector/blob/main/Yeelight_Inter_Operation_Spec_UDP_R2_en.pdf), linked as protocol reference by [Yeelight's connector README](https://github.com/Yeelight/Yeelight-Chroma-Connector#readme) |

REA/Ghidra 12.1.4 corroboration:

- `.analysis/protocol/rea-decompile-udp-send-command.json`: `0x1001ca80`, evidence `ev_4b3ecc91ea39cd3fe5afa8cbde7d7a4ddec8ebdc5cb63f713187260e342d2372`.
- `.analysis/protocol/rea-decompile-update-leds.json`: `0x10025cc0`, evidence `ev_0bbf048679c533b7a75f08787dd8f5d1c8c0ed58f3531b35ab480dcba1cbe7f3`.
- `.analysis/protocol/rea-decompile-capabilities.json`: `0x1001e960`, evidence `ev_79ed18d8659bdc2c1dc31db285f28697851e76b5f85d4084f8585d0b0360d821`.
- `.analysis/protocol/rea-decompile-udp-session-new.json`: `0x10017610`, evidence `ev_b586bf050630db87fc7579a4a035a2e22dc094b5961c12e8d482efe88ff737e3`.
- `.analysis/protocol/rea-decompile-udp-keepalive.json`: `0x1001c860`, evidence `ev_2a9766a6357ac0f3a01a9fb6832f1b35e22d289ab9a49d3f4d8e323b19b60e96`.
- `.analysis/protocol/rea-decompile-json-serializer.json`: `YeeCommonLib.dll` `0x100296c0`, evidence `ev_db7abecb4bb77b95cc57a51fdefa7e6100601551dce03d21859b5a56555e6682`.
- `.analysis/protocol/rea-decompile-activate-fx-mode.json`: `0x100242f0`, evidence `ev_4ba9b7446617a58fd9705e582f596074e016538f44a78f23c23b92e2b061fb5a`.
- `.analysis/protocol/rea-daemon-resources.json`: PE32/x86 resource identity; DLL contains a manifest resource, not a protocol table.

## Discovery and ordinary LAN commands

Station's exact discovery request literal is:

```python
b'M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1982\r\nMAN: "ssdp:discover"\r\nST: wifi_bulb\r\n'
```

It ends with one CRLF after `ST`; the binary literal does not include an extra empty line. Discovery sends to UDP `239.255.255.250:1982`. The official spec says unicast replies return to the request's source address/port and header names are case-insensitive. Follow the returned `Location: yeelight://IP:PORT` for TCP; 55443 is the normal default, and a default `0xd893` occurs at daemon RVA `0x7d9c`. Station parses the advertised location rather than deriving a device endpoint from the Overwolf connector configuration. [D1; daemon `0x1b0f4–0x1b276`; P1 §3.1]

The shared serializer writes compact JSON followed by `\r\n`. Both TCP commands and proprietary UDP commands pass through it. The TCP receiver recognizes `method:"props"` and reads `params`; command replies correlate through IDs. A port must handle partial/multiple TCP frames, separate notifications from replies, and preserve advertised support strings. [D2; daemon `0x14714–0x1472c`, `0x1485c` onward]

Standard documented forms include:

```json
{"id":1,"method":"set_power","params":["on","smooth",500]}
{"id":2,"method":"set_rgb","params":[16711680,"smooth",500]}
{"id":3,"method":"set_bright","params":[50,"smooth",500]}
{"id":4,"method":"set_ct_abx","params":[4000,"smooth",500]}
{"id":5,"method":"start_cf","params":[0,0,"500,1,16711680,100,500,1,255,100"]}
```

These examples must each be followed by CRLF. `start_cf` takes count, end action, and comma-separated `(duration, mode, value, brightness)` tuples; count 0 loops, modes 1/2/7 mean RGB/CT/sleep, and end actions 0/1/2 mean restore/keep/off. [P1 §4.1]

Station's exported `SendYeeRequest_setSceneCF` builds `set_scene`/`bg_set_scene` with `params:["cf",count,action,expression]`: builder `0x24f60`, subtype at `0x250fc`, append helper `0x1620`. The helper formats each tuple using `%1,%2,%3,%4` at `0x176b` and commas between tuples. This agrees with the installer Overwolf flow presets, e.g. `1,0,600,1,10494192,100` (count, action, then one tuple). The `cf` database string includes count/action; a flow-expression string alone does not. [Daemon `0x1648–0x169d`, `0x1750–0x188b`; installer `overwolf/yeeoverwolflocalcache.db3`, `modelist.cf`]

Station also has a color-scene extension: its UDP scene builder appends `["color",rgb,brightness,duration,effect]`, with BG method prefix when selected. Duration precedes effect here. This is visible in `0x1c15b–0x1c21d`; do not copy the argument ordering from `set_rgb`. Hardware acceptance of every extended argument is untested.

## Public music mode

Public music mode: listen on TCP, send `set_music` parameters `[1,"HOST",PORT]`, and accept the light's reverse connection. Send supported CRLF commands there. Stop with `[0]` or closure. Quotas/property reports are disabled; no additional handshake is documented. [P1 §4.1, printed p.17]

**Evidence boundary:** `set_music` is in Station's recognized command list at RVA `0x11e0`, but this research has not established a Station-owned reverse-TCP listener flow. Its explicitly recovered realtime session uses UDP. Do not silently map public music mode to `udp_sess_new`, or treat `update_music_data` as an alias for either.

## Proprietary UDP session protocol

### Admission, creation, and framing

The daemon's UDP admission check looks for substring `chroma` in discovery `support` (`0x1a04b–0x1a089`). That is the behavior of this Windows build; it is broader than testing only `udp_sess_new`. It then prefers `udp_sess_new` if present, otherwise recognizes `udp_new`, selecting internal protocol value 2 or 1 respectively. [D3, D8]

Creation sends to device UDP **55444**:

```json
{"id":1,"method":"udp_sess_new","params":[]}
```

For the legacy variant the method is `udp_new`. Creation has no token field: it has a dedicated builder, not the general token-bearing command builder. IDs are generated, not fixed to 1; the example uses the initial value for readability. `udp_sess_new` and port 55444 are independently confirmed by P2. [D3, D4, D9]

Expected session-token response shape, reconstructed from the parser:

```json
{"id":1,"method":"udp_sess_token","params":{"token":"DEVICE_TOKEN"}}
```

The parser accepts `udp_token` as the legacy response method. It requires `params` to be a JSON object, reads its `token` as a string, stores it, switches the connection state to 2, and restarts session timers. Exact token length/encoding is not checked in the recovered branch and should not be invented. [D3, `0x1a705–0x1a8d4`; P2]

Subsequent general UDP commands have this envelope and use the same CRLF serializer:

```json
{"id":2,"method":"set_rgb","params":[16711680,"sudden",0],"token":"DEVICE_TOKEN"}
```

`token` is a **top-level JSON member**, not a prefix, suffix, or member of `params`. JSON key order is immaterial. No checksum, AES layer, or raw binary header appears in this recovered send path. [D2, D4]

The original client derives its local UDP port using a 16-bit `internalID - 0x6b90` operation (`0x1d486–0x1d498`). This is consistent with `38000 + internalID` modulo 65536. It is a Windows client bind choice, not an additional device listening port or evidence that macOS must reserve a fixed port.

### Keepalive and recovery

Station builds:

```json
{"id":3,"method":"udp_sess_keep_alive","params":["keeplive_interval",10],"token":"DEVICE_TOKEN"}
```

The misspelling **`keeplive_interval`** is literal. Legacy mode selects `udp_keep_alive`. In the binary, 10 is constructed through `QJsonValue(int)` at `0x1ca26–0x1ca2b`; P2's example uses the string `"10"`. Preserve this distinction when comparing captures. [D9; P2]

Station maintenance differs from simply following the published example's 10-second heartbeat cadence:

- With an acquired token, send another keepalive after more than 5000 ms on the send timer (`0x185df–0x18698`).
- If the receive timer exceeds 10000 ms, reacquire a token and return to state 1 (`0x18502–0x185c5`).
- State 1 retries creation after more than 5000 ms (`0x186b5–0x1877a`).
- More than 60000 ms without receive-timer progress fails the light (`0x1842a–0x184e2`).
- Ordinary control is gated on the started flag, state 2, a received-property/keepalive flag, receive freshness under 10000 ms, a nonempty trimmed token, and further local control policy. A token response alone does not satisfy all checks (`0x19f50–0x19fb6`).

The property-read callback in the run cache logs `read light prop` and calls the UDP object's receive/ready helper with `true` (`0xd381`, `0xd465–0xd467`), which sets the flag at object offset `0x84` (`0x1b7c3–0x1b7c9`). UDP heartbeat parsing restarts timers (`0x1abac–0x1abba`) but does not itself set that flag in the inspected branch. Preserve the TCP/property companion path when replicating Station's state machine; a UDP-only startup that waits for this flag can stall.

P2 documents four simultaneous UDP sessions with oldest replacement, and says only session/heartbeat messages have replies. Station additionally has a command cache/retry mechanism: a 100 ms maintenance tick, retry decisions every third counter value, and expiry after counter >10 appear at `0x17e3d–0x17e62`, `0x1805f–0x18139`. Do not require a successful reply for every color frame; device/firmware behavior needs capture validation.

`udp_chroma_sess_new` occurs in the recognized method list and retry-filter list (`0x12f6`, `0x1db55`). The automatic creation function inspected here chooses `udp_sess_new` or `udp_new`. No additional Chroma-specific handshake was established. [D3, D7]

## Segmented color and RGB packing

### Legacy segmented command

`SendYeeRequest_SetSegmentRgbColor(did, colors, count)` at RVA `0x1f1b0` calls the builder at `0x259d0`. It appends each input integer unchanged to the node parameter array:

```json
{"id":4,"method":"set_segment_rgb","params":[16711680,65280,255],"token":"DEVICE_TOKEN"}
```

This illustrates three color values, not verified physical segment ordering or a guaranteed three-segment device. The local API first wraps requests in `nodes:[{"did":...,"params":...}]`; the device packet uses the selected node's params. The run cache passes the method and array into `YeeUdpLight` (`0xec47–0xec90`), whose non-scene/non-toggle branch delegates unchanged (`0x1bd4f–0x1bd5f`). [D4, D5]

### Extended segmented command

Both `SetSegmentRgbColorEX` overloads emit method **`update_leds`**, despite their exported C++ name containing `SegmentRgbColorEX`. The list overload accepts pairs `(rgb, repeatCount)`. For each pair it appends R, G, B bytes `repeatCount` times, Base64 encodes the full byte array with default options, and places the resulting string as the sole element of params. [D6, REA `0x10025cc0`]

```text
RGB integer = (R << 16) | (G << 8) | B
bytes       = R0 G0 B0 R1 G1 B1 ...
params      = [base64(bytes)]
```

The byte extractor at `0x28f0` shifts by 16, then 8, then takes the low byte. Append instructions at `0x25e70–0x25e84` preserve R/G/B order. Alpha is not included. The pointer overload `(did, colors, count, repeatCount)` expands each input color into such a pair at `0x260a0–0x260fd`; the final argument is replication, not brightness. Zero/negative repeat counts append no bytes in the list builder. [D6, D7]

For one red, one green, one blue LED, the recovered encoding yields bytes `ff000000ff000000ff` and Base64 `/wAAAP8AAAD/`:

```json
{"id":5,"method":"update_leds","params":["/wAAAP8AAAD/"],"token":"DEVICE_TOKEN"}
```

There is no segment index, brightness, frame number, duration, or count member added by this builder. The number of encoded RGB triples is implicit in the decoded length. Exact model limits, fragmentation requirements, physical LED order and stale-frame handling remain untested; do not infer a universal maximum from this function.

## Device FX-mode command layout

The exported activation API calls builder `0x242f0`, which creates a params array of objects. Each object always has `mode` as the caller-provided string. It optionally adds:

- `speed`: present only for positive input, capped at 255 (`0x245a5–0x245b9`).
- `percent`: present only for positive input, capped at 100 (`0x24601–0x24618`).
- **`palatte`**: exact misspelling; a nonempty array of input integer colors (`0x24666–0x2470f`).

The recovered structural form is `activate_fx_mode` with `params:[{"mode":MODE,"speed":SPEED,"percent":PERCENT,"palatte":[RGB,...]},...]`. `MODE` is a placeholder, not a confirmed mode identifier. The deactivation builder emits `deactivate_fx_mode` with an empty params array (`0x24ac0–0x24b0a`). Both go through the ordinary token-bearing UDP command layer for admitted devices. [D4, D11]

The command layer removes cached deactivation when activation is issued, and vice versa (`0x1ce0c–0x1ce5f`); these methods are included in its resend-tracked subset. This provides state-transition evidence but does not establish a requirement to activate FX before `update_leds`. Supported mode strings, per-model semantics, and `update_music_data` contents still require investigation.

## BG channels, capabilities, and model handling

`ParseLightTypeJsonKey` prefixes a command with `bg_` only for light-type value **2** (`0x1e6db–0x1e72a`). `ParseMainJsonKey` can add `main_` when its boolean argument is true (`0x1e80b–0x1e85c`); do not infer that every `main_*` command is a public protocol command. [D8]

The capability classifier derives these internal flags:

| Input evidence | Result |
| --- | --- |
| Support contains `bg_` | Separate returned light-type value becomes 2 |
| Support contains `set_segment_rgb` | Device mask starts with `0x04` |
| Support contains `activate_fx_mode` | OR `0x40` |
| Also contains `update_music_data` inside that branch | OR `0x80` |
| Support contains `update_leds` | OR `0x108` |
| Trimmed/lowercased model starts with `lamp` | OR `0x02` |
| Otherwise starts with `cube` | OR `0x10` |
| Otherwise starts with `rays` | OR `0x20` |

These are bit masks, not mutually exclusive model enum values. The support checks are substring searches. Absence of a feature in a string scan does not prove absence in firmware. [D8, REA `0x1001e960`]

Station explicitly rejects a lamp-family color scene on channels other than BG, logging that lamp devices only enable RGB on BG (`0x1c015–0x1c063`). A port must preserve separate main/BG state and capability checks. Public BG methods mirror RGB/HSV/CT/power/brightness/scene/flow operations on devices with background hardware. [D8; P1 Table 4-1]

Other model-specific literals are `Chameleon2`, `CubeMatrix`, and `strip8` in a model setter at `0x3460–0x34ee`. It writes `0xd2` and/or 5 for the first two, and `0x1c` for `strip8`. Their exact field semantics are not established here; they are **not** evidence for a universal LED count, a whitelist of only three devices, or support for arbitrary devices with similar names.

No complete device whitelist was recovered from these daemon functions. Compatibility should be expressed as advertised protocol features and tested models. The packaged topology database contains example rows for **lamp15** (`device_type=2`) and **color4** (`device_type=0`), both with `mappingled=1`, `allowctrl=0`, `registered=0`. These are installer cache contents, not discovery evidence for devices on the current LAN. [D10]

The daemon initializes this recognized **set-request** method inventory (RVA `0x1150–0x1383`):

```text
set_default set_power toggle set_bright set_scene set_hsv set_music set_name
set_segment_rgb update_leds update_music_data set_rgb set_adjust set_ct_abx
cron_add cron_del start_cf stop_cf adjust_bright adjust_color adjust_ct
udp_sess_new udp_sess_keep_alive udp_chroma_sess_new
activate_fx_mode deactivate_fx_mode
```

Its separate response-handling inventory contains `get_prop` and `cron_get` (`0x10b0–0x114d`). This inventory proves recognized daemon request names, not firmware support for every command or a recovered payload schema for every method. Legacy `udp_new`/`udp_keep_alive` are selected in dedicated functions even though absent from that global inventory. [D3, D7, D9]

## Local configuration is not device protocol

The packaged `overwolf/connector.ini` says `server=127.0.0.1`, `port=33343`. That is loopback connector configuration; it does not identify a bulb port. `YeeDaemonConnectLib.dll` contains `YEEDAEMON_TCP_PORT` at file `0x11028` and client-side request names, consistent with an app-to-daemon boundary.

Scene storage in `localcache/yeeapplocalcache.db3` contains separate `parammode/bright/ct/rgb/cf` and `bg_parammode/bg_bright/bg_ct/bg_rgb/bg_cf` fields. These should remain separate in a replacement persistence model. The supplied topology DB has eight columns; the current daemon's create/load SQL references a larger schema including IP, port, support, `min_ct`, `max_ct`, `cube_topology`, and the literal misspelling `strip_lenth` (RVA `0x2e888–0x2ea78`). Do not assume the installer seed schema is the complete runtime schema.

## Compatibility obligations and remaining unknowns

Evidence supports implementing transport-independent models, SSDP-style discovery, CRLF TCP framing, main/BG commands, token-bearing UDP sessions, and two separate segmented encoders. It does not establish successful behavior against any physical device.

Before claiming Station parity, obtain captures/tests for:

1. UDP session creation, heartbeat response shape, token rollover and timeout recovery on representative firmware, including numeric vs string keepalive interval.
2. Realtime pacing and frame size limits for `set_segment_rgb` and `update_leds`; physical segment/LED ordering and repeat counts on supported hardware.
3. FX mode identifiers and semantics, and the distinct `update_music_data` payload. FX object keys/clamps and deactivation shape are recovered; accepted mode names and complete firmware behavior are not.
4. Cube topology and rays-specific state/mapping, strip length/min/max CT semantics, rotation properties, and firmware-dependent discovery headers.
5. Whether a given device accepts ordinary LAN/music mode, UDP legacy mode, UDP sessions, or multiple paths; LAN-control enablement and permission policy per model.
6. Any complete UI-side model allowlist outside the inspected daemon, and whether that is product policy rather than a transport restriction.

There is no evidence here for speculative extra device ports, a mandatory music-mode step before UDP, or an undocumented binary/AES wrapper.

## Documented sleep timers and defaults

The [official LAN specification](https://www.yeelight.com/download/Yeelight_Inter-Operation_Spec.pdf), §§4.1–4.3, documents `cron_add [0, minutes]` for delayed off, `cron_get [0]` for timer inspection, `cron_del [0]` for cancellation and `get_prop ["delayoff"]` for remaining minutes. Timer creation requires the light on. The Mac UI restricts duration to 1–60 minutes, matching the documented property range; the command's full firmware limits and replacement behaviour are not established. These contracts contain no dates, weekdays or recurring on-actions.

`set_default []` saves the current on-state for a hard-power restart; `bg_set_default []` addresses the background channel. Saved lamp15 firmware 38 discovery advertises these commands and all three `cron_*` methods. No background cron methods are advertised. No verified schema exists here for the phone app's automatic-state-save or power-resumption switches. `set_ps` is not advertised and is not used. Uptime, lamp Wi-Fi signal/network and MAC are not documented discovery/get-property fields; a device ID is not a verified MAC address.

Advertisement establishes eligibility to attempt a command, not hardware validation. Current UI behaviour and Mac-hosted scheduling requirements are defined in [everyday light controls](../product/everyday-light-controls.md).

## Reproduction

Do not execute the Windows targets. The following commands inspect copies:

```sh
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDaemonLib.dll" 0x10025cc0 --provider ghidra --json
.tools/rea-cli decompile "$PWD/.analysis/windows-app/YeeDaemonLib.dll" 0x1001ca80 --provider ghidra --json
.tools/rea-cli inspect-sqlite-database '.analysis/installer/C:/ProgramData/Yeelight Station/localcache/yeelocalcache.db3' --table dbyeelighttopology --row-limit 10 --json
.tools/protocol-venv/bin/python scripts/research/inspect_pe.py .analysis/windows-app/YeeDaemonLib.dll --start 0x28f0 --end 0x291d
.tools/protocol-venv/bin/python scripts/research/inspect_pe.py .analysis/windows-app/YeeCommonLib.dll --start 0x296c0 --end 0x29745
```

The helper requires `pefile` and `capstone` (locally installed in the ignored `.tools/protocol-venv`). Byte/RVA mapping uses PE section headers. Whole-section xref scans are linear disassembly and can encounter inline data; use REA's analyzed function boundaries to corroborate conclusions.
