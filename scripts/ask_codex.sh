#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_codex.sh <task> [options]
  ask_codex.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task (backward compat)
  (stdin)                      Pipe task text via stdin if no arg/flag given

File context (optional, repeatable):
  -f, --file <path>            Priority file path
  -i, --image <path>           Image to attach to the default Codex runtime

Multi-turn:
      --session <id>           Resume a previous session (thread_id from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --reasoning <level>      Optional reasoning override; normally use configured high
      --sandbox <mode>         Sandbox mode override
      --read-only              Read-only sandbox (no file changes)
      --full-auto              Compatibility alias for workspace-write (default)
      --ephemeral              Do not persist the Codex session
      --output-schema <path>   Require the final response to match a JSON Schema
      --notify                 Desktop notification when a long run finishes (macOS/Linux; opt-in)
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Output (on success):
  session_id=<thread_id>       Use with --session for follow-up calls
  runtime=<default|deepseek>   Automatically selected Codex runtime
  output_path=<file>           Path to response markdown
  result_path=<file>           Structured run status and metadata
  events_path=<file>           Raw Codex JSONL events for diagnostics

Examples:
  # New task (positional)
  ask_codex.sh "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_codex.sh "Also add retry logic" --session <id>

  # Read-only structured analysis with an attached image (default runtime only)
  ask_codex.sh "Compare the screenshot with the implementation" --read-only \
    --image screenshot.png --output-schema result.schema.json
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

configure_runtime() {
  local deepseek_home="${CODEX_DEEPSEEK_HOME:-$HOME/.codex-deepseek}"
  selected_runtime="default"

  if [[ ! -f "$deepseek_home/config.toml" ]]; then
    if [[ -n "${CODEX_DEEPSEEK_HOME:-}" ]]; then
      echo "[ERROR] CODEX_DEEPSEEK_HOME is set but config.toml is missing: $deepseek_home/config.toml" >&2
      exit 1
    fi
    return 0
  fi

  if [[ ! -f "$deepseek_home/models.json" ]]; then
    echo "[ERROR] DeepSeek Codex is configured but models.json is missing: $deepseek_home/models.json" >&2
    exit 1
  fi

  export CODEX_HOME="$deepseek_home"
  selected_runtime="deepseek"

  if [[ -z "${DEEPSEEK_API_KEY:-}" ]] && [[ "$(uname -s)" == "Darwin" ]] && command -v security >/dev/null 2>&1; then
    local deepseek_api_key
    deepseek_api_key="$(security find-generic-password -a "$USER" -s codex-deepseek-api-key -w 2>/dev/null || true)"
    if [[ -n "$deepseek_api_key" ]]; then
      export DEEPSEEK_API_KEY="$deepseek_api_key"
    fi
  fi

  if [[ -z "${DEEPSEEK_API_KEY:-}" ]]; then
    echo "[ERROR] DeepSeek Codex is configured but DEEPSEEK_API_KEY is unavailable." >&2
    exit 1
  fi
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

to_abs_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local dir
    dir="$(cd "$(dirname "$target")" && pwd)"
    echo "$dir/$(basename "$target")"
    return
  fi
  echo "$target"
}

resolve_file_ref() {
  local workspace="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -z "$cleaned" ]] && { echo ""; return; }
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" != /* ]]; then cleaned="$workspace/$cleaned"; fi
  to_abs_if_exists "$cleaned"
}

append_file_refs() {
  local raw="$1" item
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    local trimmed
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_refs+=("$trimmed")
  done
}

# --- Parse arguments ---

workspace="${PWD}"
task_text=""
model=""
reasoning_effort=""
sandbox_mode=""
read_only=false
full_auto=true
fast=false
ephemeral=false
notify=false
output_path=""
output_schema=""
session_id=""
file_refs=()
image_refs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)   workspace="${2:-}"; shift 2 ;;
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -f|--file|--focus) append_file_refs "${2:-}"; shift 2 ;;
    -i|--image)       image_refs+=("${2:-}"); shift 2 ;;
    --model)          model="${2:-}"; shift 2 ;;
    --reasoning)      reasoning_effort="${2:-}"; shift 2 ;;
    --fast)           fast=true; shift ;;
    --sandbox)        sandbox_mode="${2:-}"; full_auto=false; shift 2 ;;
    --read-only)      read_only=true; full_auto=false; shift ;;
    --full-auto)      full_auto=true; shift ;;
    --ephemeral)      ephemeral=true; shift ;;
    --output-schema)  output_schema="${2:-}"; shift 2 ;;
    --notify)         notify=true; shift ;;
    --session)        session_id="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

configure_runtime
require_cmd codex
require_cmd jq

# --- Validate inputs ---

if [[ ! -d "$workspace" ]]; then
  echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1
fi
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Request text is empty. Pass a positional arg, --task, or stdin." >&2; exit 1
fi

# --- Build file context block ---

file_block=""
if (( ${#file_refs[@]} > 0 )); then
  file_block=$'\nPriority files (read these first before making changes):'
  for ref in "${file_refs[@]}"; do
    resolved="$(resolve_file_ref "$workspace" "$ref")"
    [[ -z "$resolved" ]] && continue
    exists_tag="missing"
    [[ -e "$resolved" ]] && exists_tag="exists"
    file_block+=$'\n- '"${resolved} (${exists_tag})"
  done
fi

# --- Build prompt ---

prompt="$task_text"
if [[ -n "$file_block" ]]; then
  prompt+=$'\n'"$file_block"
fi

# --- Validate optional reasoning override ---

if [[ -n "$reasoning_effort" ]]; then
  case "$reasoning_effort" in
    minimal|low|medium|high|xhigh|max|ultra) ;;
    *) echo "[ERROR] Unsupported reasoning effort: $reasoning_effort" >&2; exit 1 ;;
  esac
  if [[ "$selected_runtime" == "deepseek" ]]; then
    case "$reasoning_effort" in
      low|high|max) ;;
      *) echo "[ERROR] DeepSeek supports only low, high, and max reasoning. Omit --reasoning to use high." >&2; exit 1 ;;
    esac
  fi
fi

if [[ -n "$session_id" && ( "$read_only" == true || -n "$sandbox_mode" ) ]]; then
  echo "[ERROR] Codex resume cannot override sandbox mode; it keeps the original session permissions." >&2
  exit 1
fi

if [[ -n "$output_schema" ]]; then
  output_schema="$(resolve_file_ref "$workspace" "$output_schema")"
  [[ -f "$output_schema" ]] || { echo "[ERROR] Output schema not found: $output_schema" >&2; exit 1; }
fi

resolved_images=()
if (( ${#image_refs[@]} > 0 )); then
  if [[ "$selected_runtime" == "deepseek" ]]; then
    echo "[ERROR] DeepSeek V4 Flash is text-only and cannot receive --image. Inspect the image in the calling Agent, then pass the visual findings as text." >&2
    exit 1
  fi
  for image_ref in "${image_refs[@]}"; do
    resolved_image="$(resolve_file_ref "$workspace" "$image_ref")"
    [[ -f "$resolved_image" ]] || { echo "[ERROR] Image not found: $resolved_image" >&2; exit 1; }
    resolved_images+=("$resolved_image")
  done
fi

# --- Prepare unique run artifacts ---

timestamp="$(date -u +"%Y%m%d-%H%M%S")"
state_root="${CODEX_SKILL_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/codex-skill}"
mkdir -p "$state_root"
run_dir="$(mktemp -d "$state_root/run-${timestamp}-XXXXXX")"
result_path="$run_dir/result.json"
events_path="$run_dir/events.jsonl"
stderr_path="$run_dir/stderr.log"
if [[ -z "$output_path" ]]; then
  output_path="$run_dir/result.md"
fi
mkdir -p "$(dirname "$output_path")"

# --- Build codex command ---

common_args=(--json --skip-git-repo-check)
if [[ -n "$reasoning_effort" ]]; then
  common_args+=(-c "model_reasoning_effort=\"$reasoning_effort\"")
fi
if [[ "$fast" == true ]]; then
  common_args+=(-c 'service_tier="fast"' -c 'features.fast_mode=true')
fi

if [[ -n "$session_id" ]]; then
  # Current Codex resume supports JSON, model/image/schema overrides, and non-git workspaces.
  cmd=(codex exec resume "${common_args[@]}")
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ "$ephemeral" == true ]] && cmd+=(--ephemeral)
  [[ -n "$output_schema" ]] && cmd+=(--output-schema "$output_schema")
  if (( ${#resolved_images[@]} > 0 )); then
    for resolved_image in "${resolved_images[@]}"; do cmd+=(--image "$resolved_image"); done
  fi
  cmd+=("$session_id" -)
else
  # New session
  cmd=(codex exec --cd "$workspace" "${common_args[@]}")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--sandbox workspace-write)
  fi
  [[ -n "$model" ]] && cmd+=(-m "$model")
  [[ "$ephemeral" == true ]] && cmd+=(--ephemeral)
  [[ -n "$output_schema" ]] && cmd+=(--output-schema "$output_schema")
  if (( ${#resolved_images[@]} > 0 )); then
    for resolved_image in "${resolved_images[@]}"; do cmd+=(--image "$resolved_image"); done
  fi
fi

# --- Progress watcher function ---

print_progress() {
  local line="$1"
  local item_type cmd_str preview
  # Fast string checks before calling jq
  case "$line" in
    *'"item.started"'*'"command_execution"'*)
      cmd_str=$(printf '%s' "$line" | jq -r '.item.command // empty' 2>/dev/null | sed 's|^/bin/zsh -lc ||; s|^/bin/bash -c ||' | cut -c1-100)
      [[ -n "$cmd_str" ]] && echo "[codex] > $cmd_str" >&2
      ;;
    *'"item.completed"'*'"agent_message"'*)
      preview=$(printf '%s' "$line" | jq -r '.item.text // empty' 2>/dev/null | head -1 | cut -c1-120)
      [[ -n "$preview" ]] && echo "[codex] $preview" >&2
      ;;
  esac
}

write_result() {
  local status="$1" exit_code="$2" error_message="${3:-}"
  local finished_at stderr_tail result_tmp
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  stderr_tail=""
  if [[ "$status" != "completed" ]]; then
    stderr_tail="$(tail -n 20 "$stderr_file" 2>/dev/null || true)"
  fi
  result_tmp="$result_path.tmp.$$"
  jq -n \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg runtime "$selected_runtime" \
    --arg run_id "$(basename "$run_dir")" \
    --arg workspace "$workspace" \
    --arg session_id "${thread_id:-}" \
    --arg final_message "${summary_text:-}" \
    --arg output_path "$output_path" \
    --arg events_path "$events_path" \
    --arg stderr_path "$stderr_path" \
    --argjson elapsed "${elapsed:-0}" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --arg stderr_tail "$stderr_tail" \
    --arg error "$error_message" \
    '{
      schema: "codex-skill.run.v1",
      status: $status,
      exit_code: $exit_code,
      runtime: $runtime,
      run_id: $run_id,
      workspace: $workspace,
      session_id: (if $session_id == "" then null else $session_id end),
      final_message: $final_message,
      output_path: $output_path,
      events_path: $events_path,
      stderr_path: $stderr_path,
      elapsed_seconds: $elapsed,
      started_at: $started_at,
      finished_at: $finished_at,
      stderr_tail: (if $stderr_tail == "" then null else $stderr_tail end),
      error: (if $error == "" then null else $error end)
    }' > "$result_tmp"
  mv "$result_tmp" "$result_path"
}

# --- Execute and capture output ---

stderr_file="$stderr_path"
json_file="$events_path"
prompt_file="$(mktemp)"
trap 'rm -f "$prompt_file"' EXIT
: > "$stderr_file"
: > "$json_file"

# Write prompt to a temp file and pipe from there to avoid shell argument
# length issues and encoding problems with very long or multi-byte prompts.
printf "%s\n" "$prompt" > "$prompt_file"

# Run codex and capture its output.
# We prefer `script` to allocate a pseudo-TTY, which forces codex to line-buffer
# its output so progress events arrive in real time. However, `script` requires a
# real controlling terminal and fails with "tcgetattr/ioctl: Operation not supported
# on socket" in socket-based environments (e.g. some Claude Code sandboxes). We
# detect this upfront and fall back to direct execution — output may arrive all at
# once at the end, but the task still completes correctly.
run_codex() {
  # BSD script (macOS): script [-q] [file [command...]]
  # util-linux script (Linux): script [-q] -c <command> [file]
  # Probe the local variant and use matching syntax for PTY allocation.
  # Falls back to direct execution if neither probe succeeds (e.g. socket stdin).
  local os
  os="$(uname -s)"
  if [[ "$os" == "Darwin" ]]; then
    if script -q /dev/null true >/dev/null 2>&1; then
      script -q /dev/null /bin/bash -c \
        "cd $(printf '%q' "$workspace") && $(printf '%q ' "${cmd[@]}") < $(printf '%q' "$prompt_file") 2>$(printf '%q' "$stderr_file")"
      return
    fi
  else
    if script -q -c "true" /dev/null >/dev/null 2>&1; then
      script -q -c \
        "cd $(printf '%q' "$workspace") && $(printf '%q ' "${cmd[@]}") < $(printf '%q' "$prompt_file") 2>$(printf '%q' "$stderr_file")" \
        /dev/null
      return
    fi
  fi
  # Fallback: direct execution (no PTY; progress events arrive in batch)
  (cd "$workspace" && "${cmd[@]}" < "$prompt_file" 2>"$stderr_file")
}

# Errexit is relaxed around the streaming pipeline so a non-zero codex exit still
# lets us surface captured output / a clear error instead of aborting silently.
started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_ts=$SECONDS
codex_status=0
set +e
run_codex | while IFS= read -r line; do
    cleaned="${line//$'\r'/}"
    cleaned="${cleaned//$'\004'/}"
    [[ -z "$cleaned" ]] && continue
    if [[ "$cleaned" != \{* ]]; then
      if [[ "$cleaned" =~ (\{\"type\":.*)$ ]]; then
        cleaned="${BASH_REMATCH[1]}"
      else
        continue
      fi
    fi
    jq -e . >/dev/null 2>&1 <<<"$cleaned" || continue
    printf '%s\n' "$cleaned" >> "$json_file"
    case "$cleaned" in
      *'"item.started"'*|*'"item.completed"'*) print_progress "$cleaned" ;;
    esac
  done
codex_status=${PIPESTATUS[0]}
set -e
elapsed=$(( SECONDS - start_ts ))

# Extract the session and latest agent message before checking status so failed
# runs still leave useful recovery metadata.
thread_id="$(jq -r 'select(.type == "thread.started") | (.thread_id // .threadId // empty)' < "$json_file" | head -1)"
[[ -z "$thread_id" ]] && thread_id="$session_id"
summary_text="$(jq -rs 'map(select(.type == "item.completed" and .item.type == "agent_message") | .item.text) | (last // "")' < "$json_file" 2>/dev/null)"

failure_text="$(jq -rs 'map(select(.type == "turn.failed" or .type == "error")) | (last // {}) | (.error.message // .message // "")' < "$json_file" 2>/dev/null)"
if (( codex_status != 0 )) || [[ -n "$failure_text" ]]; then
  result_exit_code="$codex_status"
  (( result_exit_code == 0 )) && result_exit_code=1
  error_message="$failure_text"
  [[ -z "$error_message" ]] && error_message="Codex exited with code $result_exit_code"
  write_result "failed" "$result_exit_code" "$error_message"
  echo "[ERROR] Codex command failed (exit $result_exit_code)" >&2
  [[ -n "$failure_text" ]] && echo "$failure_text" >&2
  [[ -s "$stderr_file" ]] && cat "$stderr_file" >&2
  echo "status=failed"
  echo "runtime=$selected_runtime"
  [[ -n "$thread_id" ]] && echo "session_id=$thread_id"
  echo "result_path=$result_path"
  echo "events_path=$events_path"
  exit "$result_exit_code"
fi

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi

# --- Process JSON output for new and resumed sessions ---

  # Execution trace: command executions (skipping pure file-reading/searching commands),
  # file write/patch operations, and any intermediate agent messages (the final one is
  # already shown as the summary above). Captured into a var so the section is omitted
  # entirely when empty (e.g. a pure read-only discussion).
  #
  # Note: zsh wraps commands in quotes, so after stripping the shell prefix the command
  # may start with " or ' — the regex accounts for this with [\"']?.
details="$(
    {
      jq -r '
        select(.type == "item.completed" and .item.type == "command_execution")
        | .item
        | ((.command // "") | gsub("^/bin/zsh -lc "; "") | gsub("^/bin/bash -c "; "")) as $cmd
        | select($cmd | test("^[\"'"'"']?(sed |cat |head |tail |nl |rg |grep |awk |wc |find |ls )") | not)
        | "### Shell: `" + ($cmd[0:200]) + "`\n" + (.aggregated_output // "" | .[0:800])
      ' < "$json_file" 2>/dev/null

      jq -r '
        select(.type == "item.completed" and .item.type == "tool_call")
        | .item
        | if .name == "write_file" then
            "### File written: " + (.arguments | fromjson | .path // "unknown")
          elif .name == "patch_file" then
            "### File patched: " + (.arguments | fromjson | .path // "unknown")
          elif .name == "shell" then
            "### Shell: `" + (.arguments | fromjson | .command // "unknown")[0:200] + "`\n" + (.output // "" | .[0:800])
          else empty
          end
      ' < "$json_file" 2>/dev/null

      jq -rs 'map(select(.type == "item.completed" and .item.type == "agent_message") | .item.text) | .[:-1] | .[]' < "$json_file" 2>/dev/null
    }
  )"

  # Run metrics: command count + token usage (from the turn.completed event).
cmd_count="$(jq -rs '[.[] | select(.type == "item.completed" and .item.type == "command_execution")] | length' < "$json_file" 2>/dev/null)"
usage_footer="$(jq -rs '
    (map(select(.type == "turn.completed")) | last | .usage) as $u
    | if $u then "tokens in=\($u.input_tokens) (cached \($u.cached_input_tokens)) out=\($u.output_tokens) reasoning=\($u.reasoning_output_tokens)" else "" end
  ' < "$json_file" 2>/dev/null)"

{
  [[ -n "$summary_text" ]] && printf '## Summary\n\n%s\n\n' "$summary_text"
  [[ -n "$details" ]] && printf '## Details\n\n%s\n\n' "$details"
  printf -- '---\nelapsed %ss · %s cmds' "$elapsed" "${cmd_count:-0}"
  [[ -n "$usage_footer" ]] && printf -- ' · %s' "$usage_footer"
  printf '\n'
} > "$output_path"

  # If nothing was captured, write a fallback
if [[ ! -s "$output_path" ]]; then
  echo "(no response from codex)" > "$output_path"
fi

write_result "completed" 0 ""

# --- Desktop notification for long runs (opt-in via --notify or CODEX_NOTIFY=1) ---
# Only fires past a minimum duration (default 30s) so quick tasks stay quiet.
maybe_notify() {
  [[ "${CODEX_NOTIFY:-0}" == "1" || "$notify" == true ]] || return 0
  (( elapsed >= ${CODEX_NOTIFY_MIN_SECONDS:-30} )) || return 0
  local title="Codex done (${elapsed}s)"
  local body
  body="$(printf '%s' "${summary_text:-task complete}" | tr '\n' ' ' | cut -c1-120)"
  case "$(uname -s)" in
    Darwin)
      if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1 || true
      else
        osascript -e "display notification \"${body//\"/\'}\" with title \"${title//\"/\'}\" sound name \"Glass\"" >/dev/null 2>&1 || true
      fi
      ;;
    Linux)
      command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$body" >/dev/null 2>&1 || true
      ;;
  esac
}
maybe_notify

# --- Output results ---

if [[ -n "$thread_id" ]]; then
  echo "session_id=$thread_id"
fi
echo "runtime=$selected_runtime"
echo "output_path=$output_path"
echo "result_path=$result_path"
echo "events_path=$events_path"
echo "elapsed=${elapsed}s"
