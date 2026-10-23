# Local-network access

Station discovers lights using UDP and controls them with TCP and authenticated UDP sessions. A successful TCP property probe does not prove discovery or real-time traffic is permitted.

## App setup

1. Enable LAN Control in the Yeelight phone app and put the Mac on the light's LAN.
2. Launch the installed `/Applications/Yeelight Station.app`; allow its Local Network prompt. Check **System Settings → Privacy & Security → Local Network** if it was denied. Station's Settings page links there.
3. If a network filter is installed, inspect the entry for this exact app/executable and permit its connections to the light on the LAN. For Little Snitch, use Network Monitor → the connection → **Show Corresponding Rules**. The [vendor guidance](https://www.obdev.at/en/support/littlesnitch) describes this inspection. Leave global protections enabled.
4. After approving an initial Local Network alert, choose Discover again if the first search timed out. Quit and reopen Station after replacing its installed build.

The app's bundle identity is `dev.yeelightstation.mac`; the packaged diagnostic CLI is `dev.yeelightstation.stationctl`. Standalone debug binaries and temporary probes have different identities and can have different permissions. Ad-hoc development signing may require reviewing permission again after a rebuild. Use the [Developer ID release workflow](distribution.md) for the installed copy. Notarization does not grant privacy or network-filter permission.

Apple's [TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) explains responsible-code attribution and per-executable local-network behavior. A multicast entitlement is not required on macOS.

## Diagnostics

```sh
STATION_DISCOVERY_DEBUG=1 dist/stationctl discover 192.168.8.173
dist/stationctl probe 192.168.8.173 --model lamp15
```

Discovery goes to UDP 1982; responses need not originate on 1982. The tested lamp15 firmware 38 replies from UDP **49153**. Control uses TCP 55443 and UDP 55444. Discovery checks that the response's source IP matches its advertised endpoint.

For a read-only check inside the actual installed GUI identity, use a fresh output path:

```sh
python3 scripts/research/check-packaged-discovery.py 192.168.8.173 --app '/Applications/Yeelight Station.app' --output /tmp/station-network-check.json
```

This diagnostic launches without the normal window, polling, controls or capture. It reports discovery, TCP route state and identity, then exits. The script rejects an existing report and checks process exit. It can run alongside the normal app. It does not approve network permissions or change filter rules.

`probe` is read-only. `stream-test IP --apply --seconds 8` deliberately cycles a lamp15 backlight, verifies state and restores static settings. It needs an advertised device capability list; it is not an offline test. Do not run it during another controller's color flow.

## Observed on this development Mac

The same Swift UDP probe received device replies through Apple's interpreter and timed out as a newly compiled executable. Independent Network.framework probes also showed executable-dependent behavior. Python and the StationCore library loaded into the trusted Swift test process communicated with the real light. This isolates a per-executable policy/attribution difference; it does not identify the precise enforcing firewall or privacy rule.

The macOS application firewall reported the tested CLI permitted. Little Snitch was active, but its privileged traffic-history query was unavailable to the unprivileged diagnostic command. Empty output was not interpreted as permission. No firewall, privacy rule or network filter was changed by the agent; the user subsequently reported approving the permission.

The user subsequently confirmed that the packaged app discovers, adds and controls the Light Bar Pro. The remaining daily-use issue is repeated approval during development updates; the release workflow replaces ad-hoc identity churn with a persistent Developer ID identity and canonical installation. This is a mitigation based on Apple’s guidance, not proof that every prior alert had the same cause.

The final Developer ID signed Applications build also discovered lamp15 and reached TCP 55443 from its own process identity. A prior signed probe timed out; no privacy/filter rule change was inferred from the later success. The installed copy is now notarized; see [release verification](../implementation/status.md).
