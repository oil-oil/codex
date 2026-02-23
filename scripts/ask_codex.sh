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

Multi-turn:
      --session <id>           Resume a previous session (thread_id from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --model <name>           Model override
      --reasoning <level>      Reasoning effort: low, medium, high (default: medium)
      --sandbox <mode>         Sandbox mode override
      --read-only              Read-only sandbox (no file changes)
      --full-auto              Full-auto mode (default)
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Output (on success):
  session_id=<thread_id>       Use with --session for follow-up calls
  output_path=<file>           Path to response markdown

Examples:
  # New task (positional)
  ask_codex.sh "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_codex.sh "Also add retry logic" --session <id>
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
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
output_path=""
session_id=""
file_refs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)   workspace="${2:-}"; shift 2 ;;
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -f|--file|--focus) append_file_refs "${2:-}"; shift 2 ;;
    --model)          model="${2:-}"; shift 2 ;;
    --reasoning)      reasoning_effort="${2:-}"; shift 2 ;;
    --sandbox)        sandbox_mode="${2:-}"; full_auto=false; shift 2 ;;
    --read-only)      read_only=true; full_auto=false; shift ;;
    --full-auto)      full_auto=true; shift ;;
    --session)        session_id="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

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

# --- Prepare output path ---

if [[ -z "$output_path" ]]; then
  timestamp="$(date -u +"%Y%m%d-%H%M%S")"
  skill_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  output_path="$skill_dir/.runtime/${timestamp}.md"
fi
mkdir -p "$(dirname "$output_path")"

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

# --- Determine reasoning effort ---

if [[ -z "$reasoning_effort" ]]; then
  reasoning_effort="medium"
fi

# --- Build codex command ---

if [[ -n "$session_id" ]]; then
  # Resume mode: continue a previous session
  cmd=(codex exec resume --skip-git-repo-check --json -c "model_reasoning_effort=\"$reasoning_effort\"")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--full-auto)
  fi
  [[ -n "$model" ]] && cmd+=(-m "$model")
  cmd+=("$session_id")
else
  # New session
  cmd=(codex exec --cd "$workspace" --skip-git-repo-check --json -c "model_reasoning_effort=\"$reasoning_effort\"")
  if [[ "$read_only" == true ]]; then
    cmd+=(--sandbox read-only)
  elif [[ -n "$sandbox_mode" ]]; then
    cmd+=(--sandbox "$sandbox_mode")
  elif [[ "$full_auto" == true ]]; then
    cmd+=(--full-auto)
  fi
  [[ -n "$model" ]] && cmd+=(-m "$model")
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

# --- Execute and capture JSON output ---

stderr_file="$(mktemp)"
json_file="$(mktemp)"
prompt_file="$(mktemp)"
trap 'rm -f "$stderr_file" "$json_file" "$prompt_file"' EXIT
trap 'rm -f "$stderr_file" "$json_file" "$prompt_file"' EXIT

# Write prompt to a temp file and pipe from there to avoid shell argument
# length issues and encoding problems with very long or multi-byte prompts.
printf "%s" "$prompt" > "$prompt_file"

# Use `script` to run codex in a pseudo-TTY so it line-buffers its JSONL output.
# Without this, codex block-buffers when stdout is a pipe, preventing real-time progress.
script -q /dev/null /bin/bash -c \
  "cd $(printf '%q' "$workspace") && $(printf '%q ' "${cmd[@]}") < $(printf '%q' "$prompt_file") 2>$(printf '%q' "$stderr_file")" \
  | while IFS= read -r line; do
    # Strip terminal artifacts (carriage return, ^D EOF marker)
    cleaned="${line//$'\r'/}"
    cleaned="${cleaned//$'\004'/}"
    [[ -z "$cleaned" ]] && continue
    # Only process JSON lines (must start with '{')
    [[ "$cleaned" != \{* ]] && continue
    # Write to json_file for later parsing
    printf '%s\n' "$cleaned" >> "$json_file"
    # Only parse progress-relevant events (fast string check before jq)
    case "$cleaned" in
      *'"item.started"'*|*'"item.completed"'*) print_progress "$cleaned" ;;
    esac
  done

if [[ -s "$stderr_file" ]] && grep -q '\[ERROR\]' "$stderr_file" 2>/dev/null; then
  echo "[ERROR] Codex command failed" >&2
  cat "$stderr_file" >&2
  exit 1
fi

if [[ -s "$stderr_file" ]]; then
  cat "$stderr_file" >&2
fi

# --- Extract thread_id and all messages from JSON stream ---

thread_id="$(jq -r 'select(.type == "thread.started") | .thread_id' < "$json_file" | head -1)"

# Collect all completed items: file changes, tool calls, and agent messages.
# This gives full visibility into what codex actually did, not just the last message.
{
  # 1. Show command executions (shell commands codex ran)
  jq -r '
    select(.type == "item.completed" and .item.type == "command_execution")
    | .item
    | "### Shell: `" + (.command // "unknown" | gsub("^/bin/zsh -lc "; "") | gsub("^/bin/bash -c "; ""))[0:200] + "`\n" + (.aggregated_output // "" | .[0:500])
  ' < "$json_file" 2>/dev/null

  # 2. Show file write/patch operations (tool_call style, if any)
  jq -r '
    select(.type == "item.completed" and .item.type == "tool_call")
    | .item
    | if .name == "write_file" then
        "### File written: " + (.arguments | fromjson | .path // "unknown")
      elif .name == "patch_file" then
        "### File patched: " + (.arguments | fromjson | .path // "unknown")
      elif .name == "shell" then
        "### Shell: `" + (.arguments | fromjson | .command // "unknown")[0:200] + "`\n" + (.output // "" | .[0:500])
      else empty
      end
  ' < "$json_file" 2>/dev/null

  # 3. Show all agent messages (not just the last one)
  jq -r '
    select(.type == "item.completed" and .item.type == "agent_message")
    | .item.text
  ' < "$json_file" 2>/dev/null
} > "$output_path"

# If nothing was captured, write a fallback
if [[ ! -s "$output_path" ]]; then
  echo "(no response from codex)" > "$output_path"
fi

# --- Output results ---

if [[ -n "$thread_id" ]]; then
  echo "session_id=$thread_id"
fi
echo "output_path=$output_path"
