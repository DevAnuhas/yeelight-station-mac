# App and repository artwork

The README cover uses the user-selected Station dashboard screenshot, with the generated app icon and live text. The interface is not generated, repainted, or reconstructed. [Brand and composition data](../../assets/artwork/brand-spec.json) records source images, layout and verification. The earlier affectUI layout reference guides composition only; its pixels are not redistributed.

## Assets

| Asset | Purpose |
| --- | --- |
| [readme-hero.png](../../assets/readme-hero.png) | 1600 × 800 README cover |
| [social-preview.png](../../assets/social-preview.png) | 1280 × 640 opaque social card, under 1 MB |
| [station.png](../../assets/screenshots/station.png) | User-selected 2358 × 1890 Station dashboard screenshot, copied unchanged |
| [music-flow.png](../../assets/screenshots/music-flow.png) | Actual user-started Music Flow window, used in the README's expandable screenshot |
| [app-icon.png](../../assets/app-icon.png) | Unmodified generated 1254 × 1254 RGBA source master |
| [Station.icns](../../assets/Station.icns) | Ten macOS icon representations for the application bundle |
| [readme-banner.html](../../assets/artwork/readme-banner.html) | Portable deterministic cover composition |
| [app-icon-prompt.json](../../assets/app-icon-prompt.json) | Exact image-generation prompts, chosen output and tool provenance |

The colorful Dock/Finder icon uses a large silver light bar and broad RGB wash. The menu bar retains its native monochrome lightbulb symbol. No app logic, capture behavior or protocol changes accompany this artwork update.

## Sidebar wordmark

The sidebar uses the user-supplied Yeelight logo, with no additional “Station for Mac” subtitle. The original transparent [light logo](../../Sources/YeelightStation/Resources/yeelight-logo-light.png) keeps black lettering; the generated [dark logo](../../Sources/YeelightStation/Resources/yeelight-logo-dark.png) uses white lettering. The red symbol and horizontal lockup are retained. [Logo generation provenance](../../assets/yeelight-logo-prompt.json) records the built-in imagegen edit and source.

The app follows macOS appearance. Shared semantic backgrounds, readable accent text and the color popover adapt with it. The wordmark is an original-color image rather than a monochrome template. Both PNGs ship in the app's resource bundle; `--self-test` validates them after relocation.

## Capture and render

Capture the actual app window with macOS window capture, for example `screencapture -x -o -l WINDOW_ID output.png`, using the current window ID. Capture only Station, and check the result for unrelated windows or sensitive content. Do not enable screen/audio sync merely to populate a screenshot. The current dashboard source is the user's supplied screenshot. The earlier Music Flow capture records the user's already-running session; no sync was started to produce repository artwork.

The HTML references the source PNGs with relative paths and can be opened locally. It uses one 2000 × 1000 logical artboard scaled uniformly to the output width. Export the whole stage at 1600 × 800 for the README and 1280 × 640 for the social card. At the README size, the actual dashboard occupies 888 pixels, below its 2358-pixel source width. Its original aspect ratio and complete interface are retained. The current source is the user-provided `Screenshot 2026-10-24 at 4.44.39 AM.png`; its SHA-256 is recorded in the brand data. Keep native screenshot chrome and interface pixels intact.

The committed exports were produced with `html_preview`. That renderer accepts absolute local image paths, so replace the relative paths in memory before rendering. Check console image-load reports, dimensions and text clipping. The original source remains portable and relative. Screenshot exports are checked visually before replacing the committed PNGs.

GitHub's actual social-preview setting is a separate repository setting. The ready PNG follows [GitHub's size and format guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview). A repository administrator can upload it under Settings → Social preview → Edit. Updating the README image does not set this GitHub field automatically.

## Build the macOS icon

The master was produced with the built-in image-generation tool; generation details are in the prompt JSON. The converter performs technical resizing only, preserves alpha and supported RGB profiles, and does not redraw the design. It accepts square PNG masters of at least 1024 pixels and downsamples each representation directly from the original.

```sh
swift scripts/make-icon.swift .analysis/artwork/Station.iconset
iconutil -c icns .analysis/artwork/Station.iconset -o assets/Station.icns
```

Inspect 16, 32 and 64 pixel versions on light and dark backgrounds. Keep the generated source master and final ICNS in Git; working iconsets, discarded generations and screenshots used only for QA stay under ignored `.analysis/`.

Changing bundle artwork invalidates the old resource signature. Build, sign and notarize a new version using the [distribution workflow](distribution.md); do not patch a signed installed bundle's icon in place. Preserve the bundle identifier and Developer ID team across updates.
