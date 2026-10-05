# hw_agent

Minimal agentic harness in Odin. Provider-neutral loop, JSONL sessions,
pi-style compaction, JSONL stdio RPC front-end, and a shared socket daemon
(`serve/`) that every native app can drive. Intended backend for hw_launcher.
File search is fff (`fff/` bindings, `fff_bridge/` Rust crate): fff-mcp's own
find_files / grep / multi_grep, statically linked, one index per project root,
frecency shared with fff.nvim.

## Commands

- `./test.sh` — build and run every package test
- `./build.sh [debug|release]` — builds fff_bridge first (`scripts/build_fff.sh`:
  pinned fff checkout in `build/fff/src`, needs cargo), then `build/hw_agent` (debug) or
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

Project instructions (`instructions/`) go into every session's system prompt:
`~/.agents/AGENTS.md`, then `AGENTS.md` (else `CLAUDE.md`) from the git root down
to the session's cwd, 32 KB each; `created`/`snapshot` list the files loaded.
Read when a session starts or resumes, not live.

`bash` runs each command in its own process group (120 s default timeout, `timeout`
argument up to 3600): abort or timeout stops the whole group, and processes left
running when bash exits are stopped too.

Daemon sessions each have a working directory (`create` takes `cwd`, default
the daemon's); tools and the fff index use it. Bump `FFF_REVISION` in
`scripts/build_fff.sh` to follow a new fff-mcp release.

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

Raw provider traces (`HW_DEVLOG_PROFILE=dev` only): one file per request under
`~/Library/Application Support/hw_agent/traces/<session-id|cli>/`, request body
on the first line, then raw response lines; pruned after 30 days. They hold
conversation content, never the API key.

## Conventions

- `ponytail:` comments mark deliberate simplifications + upgrade path.
- Non-trivial logic gets one runnable `@(test)` in the package's `*_test.odin`.
- Deferred lifetime rule: `defer` runs at end of the enclosing *block* —
  hoist session/emit wrappers to function scope (see session bus-error fix).
- Registered in `odin_libraries/odin-workspace.json` as an external application.
