# Working on Station

Read [current context](CONTEXT.md) and [documentation](docs/README.md) before changing behavior. Preserve the separation between main task-light and RGB-backlight channels. Do not turn inspection or view initialization into device writes, microphone access, or screen capture.

Protocol claims must point to the [binary evidence](docs/research/device-protocol.md) or a first-party spec. Simulator tests do not prove physical-device compatibility. Keep extracted vendor binaries, decompiler caches and tooling under ignored `.analysis/` or `.tools/`.

Validate with `swift test --build-system native` and `scripts/build-app.sh`. Capture tests use synthetic frames/audio and must not request OS permissions. Confirm app resources load after moving the packaged app away from the build checkout.

## Documentation

Use the `maintain-project-docs` skill whenever documentation is created, reorganized, or routed. Read `CONTEXT.md` and `docs/README.md` before changing documented behavior or architecture. Update the canonical source instead of duplicating facts, link related documents, and create ADRs only for durable decisions with meaningful tradeoffs.
