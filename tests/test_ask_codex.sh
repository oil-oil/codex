#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

mkdir -p "$test_tmp/bin" "$test_tmp/workspace"

# Force direct execution so the test is independent of the host's script(1)
# implementation and whether a controlling terminal is available.
cat > "$test_tmp/bin/script" <<'FAKE_SCRIPT'
#!/usr/bin/env bash
exit 1
FAKE_SCRIPT

cat > "$test_tmp/bin/codex" <<'FAKE_CODEX'
#!/usr/bin/env bash
case "${MOCK_CODEX_MODE:-success}" in
  success)
    printf '%s\n' '{"type":"thread.started","thread_id":"thread-test"}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}'
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0}}'
    ;;
  failure)
    printf 'network unavailable\n' >&2
    exit 42
    ;;
  partial_failure)
    printf '%s\n' '{"type":"thread.started","thread_id":"partial-thread"}'
    printf 'request interrupted\n' >&2
    exit 43
    ;;
esac
FAKE_CODEX

chmod +x "$test_tmp/bin/script" "$test_tmp/bin/codex"

run_wrapper() {
  PATH="$test_tmp/bin:$PATH" \
    CODEX_SKILL_STATE_HOME="$test_tmp/state" \
    "$repo_dir/scripts/ask_codex.sh" "test task" \
    --workspace "$test_tmp/workspace" \
    --output "$test_tmp/result.md"
}

extract_value() {
  local output="$1" key="$2"
  printf '%s\n' "$output" | sed -n "s/^${key}=//p" | tail -1
}

assert_contains() {
  local haystack="$1" needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *)
      printf 'Expected output to contain: %s\nActual output:\n%s\n' "$needle" "$haystack" >&2
      exit 1
      ;;
  esac
}

success_output="$(MOCK_CODEX_MODE=success run_wrapper 2>&1)"
assert_contains "$success_output" "session_id=thread-test"
assert_contains "$(cat "$test_tmp/result.md")" "## Summary"
success_result="$(extract_value "$success_output" result_path)"
[[ -f "$success_result" ]] || {
  printf 'Expected result file: %s\n' "$success_result" >&2
  exit 1
}
[[ "$(jq -r '.status' "$success_result")" == "completed" ]]
[[ "$(jq -r '.exit_code' "$success_result")" -eq 0 ]]
[[ "$(jq -r '.session_id' "$success_result")" == "thread-test" ]]
[[ -f "$(jq -r '.events_path' "$success_result")" ]]

set +e
failure_output="$(MOCK_CODEX_MODE=failure run_wrapper 2>&1)"
failure_exit=$?
set -e
[[ "$failure_exit" -eq 42 ]] || {
  printf 'Expected exit 42, got %s\n%s\n' "$failure_exit" "$failure_output" >&2
  exit 1
}
assert_contains "$failure_output" "Codex command failed (exit 42)"
assert_contains "$failure_output" "network unavailable"
failure_result="$(extract_value "$failure_output" result_path)"
[[ "$(jq -r '.status' "$failure_result")" == "failed" ]]
[[ "$(jq -r '.exit_code' "$failure_result")" -eq 42 ]]
[[ "$(jq -r '.stderr_tail' "$failure_result")" == "network unavailable" ]]

set +e
partial_output="$(MOCK_CODEX_MODE=partial_failure run_wrapper 2>&1)"
partial_exit=$?
set -e
[[ "$partial_exit" -eq 43 ]] || {
  printf 'Expected exit 43, got %s\n%s\n' "$partial_exit" "$partial_output" >&2
  exit 1
}
assert_contains "$partial_output" "Codex command failed (exit 43)"
assert_contains "$partial_output" "request interrupted"
partial_result="$(extract_value "$partial_output" result_path)"
[[ "$(jq -r '.status' "$partial_result")" == "failed" ]]
[[ "$(jq -r '.exit_code' "$partial_result")" -eq 43 ]]
[[ "$(jq -r '.session_id' "$partial_result")" == "partial-thread" ]]

printf 'ask_codex.sh tests passed\n'
