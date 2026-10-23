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

The script uploads the signed app once, records the submission ID privately under `.analysis/notarization`, waits for Apple's decision, and retrieves the log. An Accepted result is followed by app-ticket stapling, ticket validation, Gatekeeper assessment and recreation of the ZIP from the stapled app, with the project MIT `LICENSE` as a top-level archive sibling. The notice is outside the app bundle and does not change its accepted signature. A signed build without that successful process is not called notarized.

If the wait times out, Apple may still be processing the upload. Resume the existing submission using the receipt directory printed by the script; do not rebuild, re-sign or upload again blindly:

```sh
KEYCHAIN_PROFILE='Station-Notary' scripts/notarize-app.sh --resume '/absolute/receipt/directory'
```

## Create the DMG

The drag-to-Applications image is built headlessly with [dmgbuild](https://dmgbuild.readthedocs.io/en/latest/settings.html). Its hash-pinned dependencies install into ignored `.tools/dmgbuild`; Python 3.10 or later is required. The app must already pass signature, stapled-ticket and Gatekeeper checks.

```sh
scripts/setup-dmg.sh
CODE_SIGN_IDENTITY='<Developer ID Application certificate fingerprint>' scripts/build-dmg.sh
KEYCHAIN_PROFILE='Station-Notary' scripts/notarize-dmg.sh
```

The output is `dist/Yeelight-Station-<version>-universal.dmg`, using the built app's version. It includes both architecture slices, the MIT license, an Applications shortcut, a Retina background and a saved Finder layout. The build verifies a mounted copy before publishing the signed image. Recreate the background with `swift scripts/make-dmg-background.swift packaging/dmg` when changing its source.

Keep Finder metadata changes on the volume, outside the signed app. In particular, dmgbuild's `hide_extensions` option writes `com.apple.FinderInfo` to the app and causes mounted-bundle strict signature verification to fail. Finder already treats `.app` extensions specially. The saved window includes room for path/status bars, which can follow the user's Finder preferences despite per-volume visibility flags.

The DMG container has its own notarization submission and stapled ticket, in addition to the app ticket inside it. The notary script preserves an immutable submission image and private receipts, then atomically replaces the distribution image only after Apple accepts it and signature, ticket, image and Gatekeeper checks pass. For a timeout or connection failure, resume the recorded submission rather than uploading again:

```sh
KEYCHAIN_PROFILE='Station-Notary' scripts/notarize-dmg.sh --resume '/absolute/DMG/receipt/directory'
```

Generate `SHA256SUMS.txt` from the final stapled DMG and recreated ZIP, after notarization changes have finished. Neither a checksum from the pre-stapled image nor an old ZIP checksum describes the final download.

Run the isolated packaging regressions when changing these scripts. They substitute signing, notarization and disk tools with fixtures, so they perform no uploads or real mounts:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_dmg.py' -v
```

## Install

For published downloads, open the DMG, drag **Yeelight Station** to the **Applications** shortcut, then eject the image and launch the installed copy. The image includes the MIT license. A ZIP is available as an alternate download on the same release page.

Quit Station through its menu so capture stops and the configured light restoration completes. Replace the app only after it has exited; leave the settings file in Application Support intact.

```sh
scripts/install-app.sh
open '/Applications/Yeelight Station.app'
```

The installer requires a valid Developer ID signature, stapled ticket and Gatekeeper acceptance by default. It refuses running processes, unrelated bundles, symlink destinations and an ad-hoc downgrade. It stages a verified copy in Applications and atomically swaps the bundle, keeping the prior copy until the installed app verifies. User data outside the bundle is untouched. An explicit `--allow-unnotarized` mode permits a Developer ID signed local installation while notarization credentials are being configured; it makes no Gatekeeper or notarization claim.

Launch the installed copy for daily use. Closing its window leaves the menu bar icon and any deliberately started sync running. Click or right-click the icon for controls, saved scenes, Settings and Quit. Enable **Start in the menu bar at login** only if desired; login launch must not start screen or microphone capture automatically.

For connection recovery, see [local-network access](local-network.md). See [verification status](../implementation/status.md) for what has actually been signed, notarized, installed and tested.

## Publish on GitHub

Create a GitHub release for the version tag and attach the notarized DMG, alternate ZIP and `SHA256SUMS.txt`. A tag by itself has no downloadable app assets. Publish regular releases with **Set as the latest release** enabled; GitHub excludes drafts and prereleases from its Latest channel. Keep experimental builds marked as prereleases. See [GitHub's release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release) and [release creation options](https://cli.github.com/manual/gh_release_create).

After committing and pushing the release source and annotated tag, publish from the prepared artifacts. Substitute the intended version and a file containing reviewed release notes:

```sh
gh release create v0.2.4 \
  dist/Yeelight-Station-0.2.4-universal.dmg \
  dist/Yeelight-Station-macOS.zip dist/SHA256SUMS.txt \
  --verify-tag --latest \
  --title 'Yeelight Station 0.2.4' \
  --notes-file /path/to/release-notes.md
```

Verify that `gh release list --json tagName,isLatest,isPrerelease,isDraft` reports the intended release as Latest, non-prerelease and non-draft. Download its assets anonymously and compare their SHA-256 hashes with the published checksums before handing out the links.
