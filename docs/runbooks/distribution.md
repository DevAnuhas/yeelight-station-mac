# Install and update Station

Station's daily-use copy belongs at `/Applications/Yeelight Station.app`. Keep its bundle identifier (`dev.yeelightstation.mac`), Developer ID team and designated signing requirement compatible across updates. Avoid alternating between ad-hoc builds, renamed copies and the installed release. User settings and paired lights live outside the app bundle and survive replacement.

## Permissions and identity

Developer ID signing supplies a persistent developer identity. Notarization checks the signed app and provides a Gatekeeper ticket; it does not grant Local Network, screen or microphone consent. Apple documents these separately in [Developer ID distribution](https://developer.apple.com/developer-id/), [code-signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), and [local-network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy).

The first transition from an ad-hoc build to Developer ID may require approval again. macOS and third-party network filters retain control over later authorization prompts. Do not reset privacy databases, disable filters, or cache an assumed permission grant in Station's preferences.

Basic light controls require local-network access. Color Play and the current system-audio backend request Screen & System Audio Recording access only on Start. Microphone input requests microphone access only when that source starts. Settings reads authorization state without requesting capture. Local Network has no synchronous authorization query, so Station does not display a fabricated Allowed status.

## Build a release

Use the same Developer ID Application certificate/team for subsequent builds. A development build defaults to ad-hoc signing and is unsuitable for replacing the installed release.

```sh
RELEASE=1 CODE_SIGN_IDENTITY='<Developer ID Application certificate fingerprint>' scripts/build-app.sh
```

The release build contains both Apple Silicon and Intel architectures, uses Hardened Runtime and secure signing timestamps, and verifies the expected Developer ID requirement before publishing local artifacts. `dist/stationctl` is a separate developer tool; notarizing the app archive does not establish notarization of that standalone CLI.

## Notarize

Credentials must already be saved in a `notarytool` Keychain profile. The profile name is not a password. Do not paste Apple passwords or private keys into chat, scripts, environment variables, or logs.

If a profile does not exist, its account holder can create one in their own Terminal with Apple's interactive command. Supply the release certificate's team ID; leave authentication options unspecified for secure local prompts:

```sh
xcrun notarytool store-credentials 'Station-Notary' --team-id FMS4W53T57
```

Use an Apple Developer account authorized for that team and an app-specific password when Apple requests one. The command validates and saves credentials in Keychain. Station itself never receives them. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
KEYCHAIN_PROFILE='Station-Notary' scripts/notarize-app.sh
```

The script uploads the signed app once, records the submission ID privately under `.analysis/notarization`, waits for Apple's decision, and retrieves the log. An Accepted result is followed by app-ticket stapling, ticket validation, Gatekeeper assessment and recreation of the ZIP from the stapled app. A signed build without that successful process is not called notarized.

If the wait times out, Apple may still be processing the upload. Resume the existing submission using the receipt directory printed by the script; do not rebuild, re-sign or upload again blindly:

```sh
KEYCHAIN_PROFILE='Station-Notary' scripts/notarize-app.sh --resume '/absolute/receipt/directory'
```

## Install

Quit Station through its menu so capture stops and the configured light restoration completes. Replace the app only after it has exited; leave the settings file in Application Support intact.

```sh
scripts/install-app.sh
open '/Applications/Yeelight Station.app'
```

The installer requires a valid Developer ID signature, stapled ticket and Gatekeeper acceptance by default. It refuses running processes, unrelated bundles, symlink destinations and an ad-hoc downgrade. It stages a verified copy in Applications and atomically swaps the bundle, keeping the prior copy until the installed app verifies. User data outside the bundle is untouched. An explicit `--allow-unnotarized` mode permits a Developer ID signed local installation while notarization credentials are being configured; it makes no Gatekeeper or notarization claim.

Launch the installed copy for daily use. Closing its window leaves the menu bar icon and any deliberately started sync running. Click or right-click the icon for controls, saved scenes, Settings and Quit. Enable **Start in the menu bar at login** only if desired; login launch must not start screen or microphone capture automatically.

For connection recovery, see [local-network access](local-network.md). See [verification status](../implementation/status.md) for what has actually been signed, notarized, installed and tested.
