# hw_agent

Minimal agentic harness in Odin. Provider-neutral loop, JSONL sessions,
pi-style compaction, JSONL stdio RPC front-end, and a shared socket daemon
(`serve/`) that every native app can drive. Intended backend for hw_launcher.

## Commands

- `./test.sh` — build and run every package test
- `./build.sh [debug|release]` — build `build/hw_agent` (debug) or
  `build/hw_agent-release` (embeds the Info.plist the updater pins)
- `hw-odin test <pkg>/` — one package test (`ai`, `agent`, `session`, `compact`, `rpc`, `serve`)
- `./build/hw_agent "<prompt>" [-model=<id>] [-session=<path>]` — print mode
- `./build/hw_agent -rpc [-model=<id>] [-session=<path>]` — JSONL stdio mode
- `./build/hw_agent -serve [-model=<id>]` — shared daemon on
  `~/Library/Application Support/hw_agent/agent.sock`; protocol in `serve/serve.odin`
- `./build/hw_agent -sessions` / `-show=<id>` / `-export=<id> [-json]` /
  `-rm=<id>` — list, read, export and delete daemon sessions (`-rm` goes
  through the daemon when it runs; a running session is refused)
- `./build/hw_agent -login` — prompt for the OpenRouter key (hidden) and store it
  in the Keychain (service `hw_agent`, account `openrouter`); every mode reads it
  when `OPENROUTER_API_KEY` is unset
- `./build/hw_agent -install [-model=<id>]` / `-uninstall` — LaunchAgent
  `com.halwayland.hw_agent` running `-serve`; requires a stored key

## Release and install

Releases ship a bare signed executable through `hw_odin_native_update` (pinned in
`dependencies.lock`); the installed daemon updates itself hourly, applying only
when no session is running, then exits so launchd restarts it.

- `python3 scripts/release_macos.py build <x.y.z> --notary-profile delta-support-native`
  then `python3 scripts/release_macos.py publish dist.noindex/<x.y.z>`
- First install: download `hw_agent-<x.y.z>.zip` from the latest release,
  `ditto -x -k <zip> ~/.local/bin`, then `hw_agent -login` and `hw_agent -install`.

## Testing

Default model is `deepseek/deepseek-v4.1-flash` ($0.15/M in, 1M ctx); live
verification runs use it. Auth: Keychain via `-login`, or `OPENROUTER_API_KEY`.

`HW_DEBUG=1` dumps raw SSE lines to stderr.

Dev log (`hw_odin_devlog`): journals in
`~/Library/Application Support/hw_agent/devlog/{daemon,cli}` (`HW_DEVLOG_DIR`
overrides; use `.dev-logs/` for local runs). Read with
`hw-devlog --dir <dir> summary|tail|check`; run headless checks through
`hw-devlog --dir <dir> run -- ./build/hw_agent …` and report `check`.

## Conventions

- `ponytail:` comments mark deliberate simplifications + upgrade path.
- Non-trivial logic gets one runnable `@(test)` in the package's `*_test.odin`.
- Deferred lifetime rule: `defer` runs at end of the enclosing *block* —
  hoist session/emit wrappers to function scope (see session bus-error fix).
- Registered in `odin_libraries/odin-workspace.json` as an external application.
