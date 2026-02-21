---
name: codex
description: Delegate coding tasks to Codex CLI for execution, or discuss implementation approaches with it. CodeX is a cost-effective, strong coder — great for batch refactoring, code generation, multi-file changes, test writing, and multi-turn implementation tasks. Use when the plan is clear and needs hands-on coding. Claude handles architecture, strategy, copywriting, and ambiguous problems better.
---

# CodeX — Your Codex Coding Partner

Delegate coding execution to Codex CLI. CodeX turns clear plans into working code.

## Critical rules

- ONLY interact with CodeX through the bundled shell script. NEVER call `codex` CLI directly.
- Run the script ONCE per task. If it succeeds (exit code 0), read the output file and proceed. Do NOT re-run or retry.
- Do NOT read or inspect the script source code. Treat it as a black box.

## How to call the script

The script path is:

```
~/.claude/skills/codex/scripts/ask_codex.sh
```

Minimal invocation:

```bash
~/.claude/skills/codex/scripts/ask_codex.sh "Your request in natural language"
```

With file context:

```bash
~/.claude/skills/codex/scripts/ask_codex.sh "Refactor these components to use the new API" \
  --file src/components/UserList.tsx \
  --file src/components/UserDetail.tsx
```

With explicit workspace:

```bash
~/.claude/skills/codex/scripts/ask_codex.sh "Fix the bug" \
  --workspace /other/project/path
```

Multi-turn conversation (continue a previous session):

```bash
~/.claude/skills/codex/scripts/ask_codex.sh "Also add retry logic with exponential backoff" \
  --session <session_id from previous run>
```

The script prints on success:

```
session_id=<thread_id>
output_path=<path to markdown file>
```

Read the file at `output_path` to get CodeX's response. Save `session_id` if you plan follow-up calls.

## Decision policy

Call CodeX when at least one of these is true:

- The implementation plan is clear and needs coding execution.
- The task involves batch refactoring, code generation, or repetitive changes.
- Multiple files need coordinated modifications following a defined pattern.
- You want a practitioner's perspective on whether a plan is feasible.
- The task is cost-sensitive and doesn't require deep architectural reasoning.
- Writing or updating tests based on existing code.
- Simple-to-moderate bug fixes where the root cause is identified.

Handle it yourself when:

- The task requires architecture design, technical strategy, or tradeoff analysis.
- Copywriting, documentation prose, or nuanced communication is needed.
- Deep contextual understanding of business requirements is critical.
- The problem is ambiguous and needs clarification before any code is written.

## Workflow

### Task delegation (most common)

1. Design the solution and break it into concrete steps.
2. Run the script with the task describing exactly what to implement.
3. Pass relevant files with `--file` so CodeX has context.
4. Read the output — CodeX executes changes and reports what it did.
5. Review the changes in your workspace.

### Discussion mode

1. Run the script with a question-oriented task.
2. Pass the relevant files for CodeX to analyze.
3. Read its feedback — it thinks from an implementer's perspective.
4. Combine its practical insights with your architectural judgment.

### Multi-step projects

Use `--session` to continue the conversation with context:

1. First call: core implementation. Save the `session_id` from output.
2. Review output, then second call with `--session <id>`: tests and edge cases.
3. Third call with `--session <id>` if needed: cleanup and polish.

Each follow-up call carries the full conversation history.

## File reference guidance

- Use `--file` with workspace-relative or absolute paths.
- Include 2-6 high-signal files rather than dumping everything.
- CodeX runs with full workspace access, so it can discover related files on its own.

## Options

- `--workspace <path>` — Target workspace directory (defaults to current directory).
- `--session <id>` — Resume a previous session for multi-turn conversation.
- `--model <name>` — Override model (default: uses Codex config).
- `--sandbox <mode>` — Override sandbox policy (default: workspace-write via full-auto).
- `--read-only` — Run in read-only mode for pure discussion/analysis, no file changes.

## Execution notes

- CodeX runs with `--full-auto` by default, meaning it can read and write files in the workspace autonomously.
- Keep task text concrete and actionable. Vague requests get vague results.
- When CodeX's suggestions conflict with your architectural decisions, your judgment takes priority.
