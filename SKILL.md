---
name: codex
description: Delegate coding and image-generation tasks to Codex CLI for execution. Only invoke this skill when the user explicitly asks to use Codex — e.g., "用 codex 来做", "让 codex 执行", "ask codex to...", "codex 帮我写", "让 codex 生成/画一张图". Do not proactively delegate to Codex for requests the user didn't specifically ask Codex to handle. Codex is an autonomous agent with the same tools as Claude (file read/write, grep, bash) plus a built-in image_gen tool — it explores the codebase and implements changes on its own. Codex is strong at execution and writing code but comparatively weak at understanding ambiguous problems and high-level design, so Claude's job is to do the understanding and design first, then hand Codex a clear, well-scoped task to execute.
---

## What Codex is good and bad at

Codex is an autonomous agent with the same tools as Claude (file read/write, grep, bash) plus a built-in image generator. Match the work to its profile:

- **Strong at execution and coding.** Once a task is well-defined, it implements quickly and competently — writing code, refactoring, applying mechanical changes across many files, wiring boilerplate, and generating images from a clear brief.
- **Weaker at understanding and design.** It is comparatively poor at disambiguating vague requirements, weighing architectural trade-offs, or judging what the *right* solution is. It tends to take the prompt literally and run with the first plausible interpretation.

So **Claude owns the thinking; Codex owns the doing.** Before delegating, do the understanding and design yourself: figure out what's actually needed, make the key decisions, and hand Codex a clear, well-scoped task with explicit constraints. Don't hand it an open-ended "figure out the best approach" — decide the approach, then let it execute.

## Critical rules

- Use the bundled shell script rather than calling `codex` CLI directly — the script handles output capture, session tracking, and real-time progress streaming correctly.
- Run the script once per task. If it succeeds (exit code 0), read the output file and proceed. Don't re-run just because the output seems short — Codex often makes changes quietly without narrating every step.
- Quote file paths containing `[`, `]`, spaces, or special characters (e.g. `--file "src/app/[locale]/page.tsx"`). Without quotes, zsh treats `[...]` as a glob pattern and fails with "no matches found".
- **Keep the task prompt to the goal and constraints, not the implementation steps.** Aim for under ~500 words. Codex has the same tools as Claude and will explore the codebase itself — spelling out every file to change or every step tends to constrain it rather than help.
- **Don't paste file contents into the prompt.** Use `--file` to point Codex to key files — it reads them directly at their current version. Pasting contents wastes tokens and risks passing stale code.
- **Don't mention this skill or its configuration in the prompt.** Codex doesn't need to know about it.

## How to call the script

### Linux/macOS (bash)

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

Multi-turn conversation (continue a previous session):

```bash
~/.claude/skills/codex/scripts/ask_codex.sh "Also add retry logic with exponential backoff" \
  --session <session_id from previous run>
```

### Windows (PowerShell)

The script path is:

```
~/.claude/skills/codex/scripts/ask_codex.ps1
```

Minimal invocation:

```powershell
& ~/.claude/skills/codex/scripts/ask_codex.ps1 "Your request in natural language"
```

With file context:

```powershell
& ~/.claude/skills/codex/scripts/ask_codex.ps1 "Refactor these components to use the new API" `
  -f src/components/UserList.tsx `
  -f src/components/UserDetail.tsx
```

Multi-turn conversation (continue a previous session):

```powershell
& ~/.claude/skills/codex/scripts/ask_codex.ps1 "Also add retry logic with exponential backoff" `
  -Session <session_id from previous run>
```

### Output format

The script prints on success:

```
session_id=<thread_id>
output_path=<path to markdown file>
```

Read the file at `output_path` to get CodeX's response. Save `session_id` if you plan follow-up calls.

## Workflow

1. Understand the problem: read the key files to grasp what's broken or needed. Focus on being able to describe the problem and goal clearly — you don't need to design the full solution or enumerate every affected file. Codex will explore the codebase itself.
2. Run the script with a focused task description: the goal, key constraints, and any non-obvious context. For discussion or analysis without changes, use `--read-only`.
3. Pass 1-4 entry-point files with `--file` as starting hints. Codex has the same tools as Claude and will discover related files on its own — no need to enumerate everything upfront.
4. Read the output — Codex executes changes and reports what it did.
5. Review the changes in your workspace.

For multi-step projects, use `--session <id>` to continue with full conversation history. For independent parallel tasks, use the Task tool with `run_in_background: true`.

## Generating images

Codex has a built-in image generator — the `image_gen` tool (callable name `image_gen.imagegen`), backed by OpenAI's gpt-image model. (Codex's own tool schema does not expose the exact model id, so don't rely on a specific version.) You invoke it like any other task: just ask Codex, in plain language, to generate the image. There is no extra script flag.

- **Prompt is the only knob.** The tool exposes a single input: a natural-language `prompt`. There are **no structured parameters** for size, aspect ratio, quality, output format, image count, or transparent background. Put all of that art direction *into the prompt text itself* (e.g. "a square logo…", "on a transparent background", "photorealistic, soft morning light"). Editing an attached reference image is mentioned by the tool but is not exposed as a separate parameter.
- **Output goes outside the workspace.** Generated images are always written as **PNG** to `~/.codex/generated_images/<id>/ig_<hash>.png` — *not* into `--workspace`. Output is large and roughly square (≈1254×1254 observed); you cannot set exact pixel dimensions via a parameter, only describe them in the prompt.
- **Make Codex hand you the file.** The cleanest pattern is to tell Codex, in the same prompt, to copy the generated PNG to a known path and report it — e.g. "after generating, copy the PNG to ./out/logo.png and print its absolute path." Codex has bash access and will do this. Otherwise, the result is the newest file under `~/.codex/generated_images/`.
- **Use the default (workspace-write) run.** Generation is confirmed working in the normal run; don't pair it with `--read-only`. It needs network access, and is subject to the image tool's content policy. Exact rate limits and max resolution are not exposed.

## Failure handling

- **`script: tcgetattr/ioctl: Operation not supported on socket`** (exit code 1): the `script` command probes stdin with `tcgetattr` at startup and only tolerates `ENOTTY`/`ENODEV` errors. When Claude Code connects stdin via a socketpair, the kernel returns `EOPNOTSUPP` instead — which `script` doesn't whitelist, so it exits immediately. The script detects this automatically by probing with `script -q /dev/null true` first and falls back to direct execution. Update to the latest version if you still see this error.
- **Exit code 137**: the task was interrupted (user cancel or OOM). Not a Codex bug — retry or break the task into smaller pieces.
- **`ERROR codex_core::codex: failed to load skill ...`** in stderr: one of Codex's own installed skills has a broken YAML file. This warning is harmless and doesn't affect the current task — ignore it.
- **`(no response from codex)`** in the output file: Codex ran but produced no readable output. Check stderr for clues; the task may have hit a sandbox restriction.

## Options

- `--workspace <path>` — Target workspace directory (defaults to current directory).
- `--file <path>` — Point CodeX to key entry-point files (repeatable, workspace-relative or absolute). Don't duplicate their contents in the prompt.
- `--session <id>` — Resume a previous session for multi-turn conversation.
- `--model <name>` — Override model (default: uses Codex config).
- `--reasoning <level>` — Reasoning effort: `low`, `medium`, `high` (default: `medium`). Use `high` for code review, debugging, complex refactoring, or root cause analysis.
- `--sandbox <mode>` — Override sandbox policy (default: workspace-write via full-auto).
- `--read-only` — Read-only mode for pure discussion/analysis, no file changes.

## Resume mode limitations

When using `--session` to resume a previous conversation, note these limitations:

- **Must run in a git repository** — The `codex exec resume` command requires a git-trusted directory. It does not support `--skip-git-repo-check`.
- **Limited options** — Resume mode only supports `-c/--config` and `--last`. The following options are **not supported** in resume mode:
  - `--sandbox`
  - `--full-auto`
  - `--read-only`
  - `--model`
  - `--workspace` (resumes in the original session's context)
- **Text output only** — Resume mode returns plain text instead of JSON-structured output.
