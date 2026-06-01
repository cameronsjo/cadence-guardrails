#!/usr/bin/env bash
# Tests for hooks/run-cadence-hooks.sh dispatch behavior.
#
# Covers the fail-open contract (ADR 0008) and the stale-binary soft-fail
# (cadence-hooks#39 P0): a binary that's installed but predates a subcommand
# must not block tool calls.
#
# Usage: ./tests/test-wrapper.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WRAPPER="$SCRIPT_DIR/../hooks/run-cadence-hooks.sh"

pass=0
fail=0

# Each test gets its own PATH sandbox containing (at most) a fake cadence-hooks.
make_sandbox() {
  mktemp -d
}

run_test() {
  local desc="$1" expected_exit="$2" sandbox="$3"
  shift 3
  local stdout_file stderr_file
  stdout_file=$(mktemp)
  stderr_file=$(mktemp)

  # Sandbox PATH: fake binary dir + system dirs only. Excludes /opt/homebrew/bin
  # and ~/.cargo/bin so a real cadence-hooks install can't leak into the test.
  # `|| actual_exit=$?` keeps set -e from aborting on expected non-zero exits.
  local actual_exit=0
  echo '{"tool_name":"Bash","tool_input":{"command":"git status"}}' \
    | env PATH="$sandbox:/usr/bin:/bin" bash "$WRAPPER" "$@" >"$stdout_file" 2>"$stderr_file" \
    || actual_exit=$?

  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "PASS: $desc (exit $actual_exit)"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc — expected exit $expected_exit, got $actual_exit"
    echo "      stderr: $(cat "$stderr_file")"
    fail=$((fail + 1))
  fi

  # Export for content assertions
  LAST_STDOUT=$(cat "$stdout_file")
  LAST_STDERR=$(cat "$stderr_file")
  rm -f "$stdout_file" "$stderr_file"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $desc"
    pass=$((pass + 1))
  else
    echo "FAIL: $desc — expected to contain '$needle', got '$haystack'"
    fail=$((fail + 1))
  fi
}

echo "=== 1. Binary missing: fail open (ADR 0008) ==="
sandbox=$(make_sandbox)
run_test "missing binary exits 0" 0 "$sandbox" guardrails guard-push-remote

echo "=== 2. Stale binary: unrecognized subcommand fails open (#39 P0) ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "error: unrecognized subcommand 'guard-dotfiles'" >&2
echo "Usage: cadence-hooks guardrails <COMMAND>" >&2
exit 2
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "stale binary (unrecognized subcommand) exits 0" 0 "$sandbox" guardrails guard-dotfiles

echo "=== 3. Stale binary, clap v3 wording: wasn't recognized fails open (#39 P0) ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "error: The subcommand 'guard-dotfiles' wasn't recognized" >&2
echo "Usage: cadence-hooks guardrails <COMMAND>" >&2
exit 2
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "stale binary (clap v3 wording) exits 0" 0 "$sandbox" guardrails guard-dotfiles

echo "=== 4. Real block: exit 2 and stderr propagate ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "BLOCKED: test guard" >&2
exit 2
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "blocking guard exits 2" 2 "$sandbox" guardrails guard-push-remote
assert_contains "block message reaches stderr" "$LAST_STDERR" "BLOCKED: test guard"

echo "=== 5. Allow with nudge: exit 0 and stdout propagate ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"nudge text"}}'
exit 0
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "nudge exits 0" 0 "$sandbox" guardrails warn-main-branch
assert_contains "nudge JSON reaches stdout" "$LAST_STDOUT" "additionalContext"

echo "=== 6. Stdin passthrough ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
input=$(cat)
echo "got: $input"
exit 0
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "stdin reaches binary" 0 "$sandbox" guardrails guard-push-remote
assert_contains "binary received hook JSON on stdin" "$LAST_STDOUT" '"tool_name":"Bash"'

echo "=== 7. Other failures still propagate (not swallowed by soft-fail) ==="
sandbox=$(make_sandbox)
cat >"$sandbox/cadence-hooks" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "error: something else went wrong" >&2
exit 1
FAKE
chmod +x "$sandbox/cadence-hooks"
run_test "non-stale failure keeps its exit code" 1 "$sandbox" guardrails guard-push-remote
assert_contains "non-stale stderr propagates" "$LAST_STDERR" "something else went wrong"

echo ""
echo "=== RESULT: $pass passed, $fail failed ==="
exit "$fail"
