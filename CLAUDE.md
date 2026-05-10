# cadence-guardrails

## Architecture

Hooks dispatch to the `cadence-hooks` Rust binary via `run-cadence-hooks.sh`.
Binary source: `cameronsjo/cadence-hooks` (private). Install via `brew install cameronsjo/tap/cadence-hooks`.

Shell scripts are thin wrappers — behavior changes require modifying and releasing the Rust binary.

## Running Tests

```bash
FORK_REPO=~/Projects/claude-configurations/superpowers-developing-for-claude-code \
OWN_REPO=~/Projects/claude-configurations/cadence-guardrails \
./tests/test-guards.sh
```

Default `FORK_REPO` path (`../../superpowers`) is retired. Always set explicitly.

## Hook Optimization

`hooks.json` supports `"if": "Bash(*pattern*)"` for pre-spawn filtering.
Glob matches against the command string — `*git push*` catches compound commands like `cd /foo && git push`.

## Gotchas

- `MUST NOT` add `version` to plugin.json — cache key uses SHA
- Binary uses its own PID (not PPID) for marker scoping — suppression only works within Claude Code runtime
- Binary's marker hash differs from shell md5 — tests discover paths dynamically
- Host-aware matching: non-github.com URLs are blocked (GHE not supported in 0.4.x)
- Fork-parent `-R` allowance not implemented in binary 0.4.x
