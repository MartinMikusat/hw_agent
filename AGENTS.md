# hw_agent

Minimal agentic harness in Odin. Provider-neutral loop, JSONL sessions,
pi-style compaction, JSONL stdio RPC front-end. Intended backend for OpenPad.

## Commands

- `hw-odin build . -out:build/hw_agent` — build
- `hw-odin test <pkg>/` — per-package tests (`ai`, `agent`, `session`, `compact`, `rpc`)
- `./build/hw_agent "<prompt>" [-model=<id>] [-session=<path>]` — print mode
- `./build/hw_agent -rpc [-model=<id>] [-session=<path>]` — JSONL stdio mode

## Testing

Live verification runs must use a cheap model — pass
`-model=deepseek/deepseek-v4.1-flash` ($0.15/M in, 1M ctx). Default model
(`anthropic/claude-haiku-4.5`) is for real use only. Auth: `OPENROUTER_API_KEY`,
falls back to `~/.local/share/opencode/auth.json` → `openrouter.key`.

`HW_DEBUG=1` dumps raw SSE lines to stderr.

## Conventions

- `ponytail:` comments mark deliberate simplifications + upgrade path.
- Non-trivial logic gets one runnable `@(test)` in the package's `*_test.odin`.
- Deferred lifetime rule: `defer` runs at end of the enclosing *block* —
  hoist session/emit wrappers to function scope (see session bus-error fix).
- Not registered in `odin_libraries/odin-workspace.json` — the workspace gate
  only scans `hw_*` dirs inside that repo; this is a standalone app.
