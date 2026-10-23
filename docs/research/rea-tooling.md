# REA tooling — executed 2026-10-23

REA is built locally and native x86 PE decompilation works. Nothing was registered in global agent configuration, and no Windows executable was run. Tooling and raw smoke-test evidence live under gitignored `.tools/`.

## Pinned installation

- Official source: [morluto/rea](https://github.com/morluto/rea), commit `ecd997e512f6e1bc18c730e67366052e0285e1a8`, package `rea-agents@6.7.0`.
- Runtime: local Node `24.22.1` and npm `11.16.0`, matching REA's `.nvmrc` / `packageManager`. The ambient Node `26.8.1` is unsupported by this REA revision. [Runtime requirements](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/package.json)
- Native engine: official [Ghidra 12.1.4 release](https://github.com/NationalSecurityAgency/ghidra/releases/tag/Ghidra_12.1.4_build), with its decompiler compiled for Apple Silicon. Existing JDK `22.0.2` at `/Library/Java/JavaVirtualMachines/jdk-22.jdk/Contents/Home` passed REA's full-JDK / host-architecture checks; no JDK was installed.

Successful setup sequence follows. `ROOT` abbreviates the absolute workspace paths used when running these commands.

```sh
ROOT=/Users/mac/.t3/projects/yeelight-station-mac
cd "$ROOT"
git clone https://github.com/morluto/rea .tools/rea
mkdir -p .tools/downloads .tools/node
curl --fail --location --silent --show-error https://nodejs.org/dist/v24.22.1/node-v24.22.1-darwin-arm64.tar.gz -o .tools/downloads/node-v24.22.1-darwin-arm64.tar.gz
curl --fail --location --silent --show-error https://nodejs.org/dist/v24.22.1/SHASUMS256.txt -o .tools/downloads/node-v24.22.1-SHASUMS256.txt
# SHA-256 checked against the official SHASUMS256.txt before extraction.
tar -xzf .tools/downloads/node-v24.22.1-darwin-arm64.tar.gz --strip-components=1 -C .tools/node
export PATH="$ROOT/.tools/node/bin:$PATH"
export npm_config_cache="$ROOT/.tools/npm-cache"
npm install --prefix .tools/npm --no-audit --no-fund --ignore-scripts npm@11.16.0
cd "$ROOT/.tools/rea"
HUSKY=0 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 node "$ROOT/.tools/npm/node_modules/npm/bin/npm-cli.js" ci --no-audit --no-fund
HUSKY=0 node "$ROOT/.tools/npm/node_modules/npm/bin/npm-cli.js" run build:cached
```

`npm ci` installed 547 packages. `build:cached` passed all 3 tasks in 6.359 seconds. It emitted a non-fatal managed-provider dynamic-import warning; npm reported pending optional esbuild/fsevents install scripts. The built CLI/MCP and native-provider smoke tests passed without approving those scripts. An initial dependency install used the Node archive's bundled npm `11.19.1`; the successful install was repeated with pinned npm `11.16.0`.

```sh
cd "$ROOT"
curl --fail --location --silent --show-error https://api.github.com/repos/NationalSecurityAgency/ghidra/releases/tags/Ghidra_12.1.4_build -o .tools/downloads/ghidra-release.json
curl --fail --location --silent --show-error https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip -o .tools/downloads/ghidra_12.1.4_PUBLIC_20260921.zip
# SHA-256 checked against the official release asset's digest before extraction.
unzip -oq .tools/downloads/ghidra_12.1.4_PUBLIC_20260921.zip -d .tools
cd "$ROOT/.tools/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/src/decompile/cpp"
make -j4 ghidra_opt ARCH_TYPE='-arch arm64' OSDIR=mac_arm_64
cd "$ROOT"
mkdir -p .tools/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/os/mac_arm_64
install -m 755 .tools/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/src/decompile/cpp/ghidra_opt .tools/ghidra_12.1.4_PUBLIC/Ghidra/Features/Decompiler/os/mac_arm_64/decompile
```

Verified download hashes:

```text
Node:   89c682593d76cd44233fa53b1563264e7de9cbb189cad169135c5b4fadfbc0a7
Ghidra: ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db
```

The Ghidra archive contains Linux/Windows decompilers but no macOS decompiler. The successful make overrides above are required on this host; REA's [installation guide](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/docs/installation.md#macos-arm64-native-decompiler) documents the same approach. Build log: `.tools/ghidra-decompiler-build.log`.

## Entry points and commands

From the project root, `.tools/rea-cli` selects local Node and exports the local `GHIDRA_INSTALL_DIR`. Calling `scripts/rea.mjs` directly without that environment variable reports Ghidra as unconfigured.

```sh
.tools/rea-cli --version                        # observed: 6.7.0
.tools/rea-cli providers --json                 # observed: ghidra available
.tools/rea-cli COMMAND --help
.tools/rea-cli mcp                              # stdio MCP, no registration needed
```

Equivalent direct invocation:

```sh
GHIDRA_INSTALL_DIR="$PWD/.tools/ghidra_12.1.4_PUBLIC" \
PATH="$PWD/.tools/node/bin:$PATH" \
.tools/node/bin/node .tools/rea/scripts/rea.mjs providers --json
```

Native PE workflow ([CLI contracts](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/cli/coreBinaryCommands.ts)):

```sh
DLL="$PWD/.analysis/windows-app/YeeDaemonLib.dll"
.tools/rea-cli analyze "$DLL" --provider ghidra --json
.tools/rea-cli search "$DLL" udp_sess_new --provider ghidra --json
.tools/rea-cli search "$DLL" udp_chroma_sess_new --provider ghidra --json
.tools/rea-cli search "$DLL" . --kind procedures --mode regex --provider ghidra --json
.tools/rea-cli xrefs "$DLL" 0x1002ff40 --provider ghidra --json
.tools/rea-cli function "$DLL" 0x1001e640 --provider ghidra --json
.tools/rea-cli decompile "$DLL" 0x1001e640 --provider ghidra --json
```

Search defaults to defined strings; use `--kind procedures` for function names. Function inventories include external functions/imported symbols, but there is no dedicated PE import-table CLI command. `instructions` returns assembly. Each CLI command closes its ephemeral Ghidra session; an optional `--snapshot /absolute/path.json` caches exact observations, not the live database. MCP permits several queries in one session (`open_binary`, `search_strings`, `list_procedures`, `analyze_function`, `procedure_pseudo_code`, `batch_decompile`). [Provider semantics](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/docs/ghidra-provider.md), [snapshot behavior](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/docs/cli.md#snapshots)

Provider-free inspection:

```sh
.tools/rea-cli inspect-artifact "$DLL" --json
.tools/rea-cli inspect-native-exports "$DLL" --json
.tools/rea-cli inspect-pe-resources "$DLL" --json
.tools/rea-cli inspect-pe-certificates "$DLL" --json
.tools/rea-cli inspect-managed-artifact "$DLL" --json
.tools/rea-cli inspect-managed-members /absolute/path/ManagedAssembly.dll --json
```

Managed inspection reads metadata, signatures and CIL without loading the assembly; it does not reconstruct C#. PE resource inspection reports names, payload ranges/hashes and icon relationships; other payloads remain opaque. [Managed guide](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/docs/managed-code-analysis.md), [PE resources](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/native/pe/PeResourceParser.ts#L250)

## Executed verification and limits

- `--version`, 12 command-specific help calls, and stdio MCP initialize/tools-list passed. MCP identified `rea@6.7.0` and listed 220 tools. Doctor's catalog identifies 168 CLI commands and 6 MCP prompts.
- Four provider-free inspections above passed on `YeeDaemonLib.dll`: exports, resources, certificates and managed identity. It has 25 exports and is native PE32 x86 with no CLI directory. SHA-256: `ba67486fef12531a2da5cdf065d665783ae037d3ae25e15f1223b33e4e752cb8`.
- Native `decompile ... 0x1001e640 --provider ghidra --json` exited 0 and returned Ghidra 12.1.4 pseudocode for `YeeDaemonLib::Init_YeeDaemon`. Evidence: `.tools/rea-evidence/decompile-YeeDaemonLib-Init.json`. This proves static native decompilation, not Windows runtime behavior.
- Native `search ... udp_sess_new --provider ghidra --snapshot ... --json` also exited 0 and located the string at `0x1002ff40`; full result and snapshot are in `.tools/rea-evidence/search-YeeDaemonLib-udp_sess_new.json` and `daemon-search.snapshot.json`.
- `providers-ready.json` reports Ghidra available with a matching Mach-O arm64 decompiler and accepted JDK 22.0.2. `GHIDRA_INSTALL_DIR` and a host-matching full JDK are required; `JAVA_HOME` is optional when suitable Java/javac are on PATH. `REA_GHIDRA_STARTUP_TIMEOUT_MS` defaults to 330000. Heap selection is `GHIDRA_HEADLESS_MAXMEM`, then `GHIDRA_MAXMEM`, then 2G. [Environment schema](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/config/environment.ts#L35)
- Hopper, IDA and Kuna remain unavailable. Hopper needs its executable (`HOPPER_LAUNCHER_PATH` override); IDA needs a supported existing engine/bridge registration via `REA_IDA_MCP_CONFIG`; Kuna needs `REA_KUNA_COMMAND`. Ghidra is sufficient here. [Provider setup](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/docs/installation.md)
- **Installer extraction gap:** REA has no NSIS/Inno Setup or actual 7z reader. `inspect-artifact` can inventory the root PE; `extract-artifact` rejects an ordinary native PE. Inspection of `.analysis/installer/app.7z` actually returned `unsupported binary format` with exit 1. Use existing `/opt/homebrew/bin/7zz` for those layers, then REA on extracted PE files. `extract-artifact` selects its own temporary destination and has no output-directory option. [Readers](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/artifacts/inventory/reader.ts#L23), [extraction refusal](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/artifacts/extraction/ArtifactExtraction.ts#L434)
- **Qt gap:** no dedicated QMetaObject/moc, QML, QRC or RCC parser was found. Generic native strings/functions work. `inspect-native-dispatch-metadata` is for Objective-C/Swift Mach-O, not Qt/PE. [Command](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/cli/coreNativeCommands.ts#L263), [reader restriction](https://github.com/morluto/rea/blob/ecd997e512f6e1bc18c730e67366052e0285e1a8/src/domain/native/objcSwiftMetadata.ts#L21)

Raw logs and JSON are in `.tools/rea-evidence/`; command help is in `.tools/rea-command-help/`. General `doctor` can report missing global skill/agent registrations and unused optional engines; those were deliberately not installed and do not block the verified CLI/MCP workflow. No root app manifest or implementation was changed by this setup.
