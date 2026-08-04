---
name: codex
description: 将编码、代码库探索、实现、评审和验证任务委托给持久化 Codex CLI Agent。仅当用户明确要求“用 Codex”“让 Codex 执行”，或要求继续某个 Codex Agent 任务时使用。
---

# Codex CLI Agent

## 核心规则

- 通过内置包装脚本调用 Codex，不要直接执行 `codex exec`。包装脚本负责捕获 JSONL、显示有效进度、记录会话 ID，并生成精简的 Markdown 结果。
- 常规调用不选择或传递模型、思考强度与模型提供商。包装脚本会自动选择本机已配置的运行环境：
  - 存在有效的 `~/.codex-deepseek/config.toml` 时使用 DeepSeek Codex。
  - 未配置 DeepSeek 时使用默认 Codex。
- DeepSeek V4 Flash 是纯文本模型。启用 DeepSeek 时不要传 `--image`；由当前 Agent 先识别图片，再把视觉结论作为文字背景交给 Codex。
- 每个任务先调用一次包装脚本。成功后读取 `output_path`，检查工作区结果，再判断是否需要继续同一会话。
- 委托提示词应包含目标、完成标准、约束和必要背景，不要规定每一个实现步骤，也不要粘贴大段文件内容。
- 使用 `--file` 提供 1–4 个重要入口文件，其余路径让 Codex 自己探索。
- 调用方仍负责范围、安全和最终验收。

## 委托契约

每次只委托一个边界清楚的任务。提示词应简短覆盖：

- 目标：要修改或查明什么，以及明确不应改动的范围。
- 完成标准：预期行为、必须覆盖的边界情况。
- 验证：从仓库配置中确认真实的测试、检查或构建命令，不要只写“运行测试”。
- 安全边界：不执行 `git add`、`git commit`，不顺手重构无关代码。
- 最终报告：说明改动与原因、涉及文件、验证结果，以及仍需决定或未完成的事项。

缺少的仓库事实应先查找；无法确认时明确报告，不要猜测。评审或诊断任务要求结论引用代码证据，并区分事实与推断。

## 包装脚本

macOS 与 Linux：

```text
~/.agents/skills/codex/scripts/ask_codex.sh
```

Windows：

```text
~/.agents/skills/codex/scripts/ask_codex.ps1
```

`~/.claude/skills/codex` 可以作为兼容软链接指向同一个 Skill。

## 常用调用

新任务：

```bash
~/.agents/skills/codex/scripts/ask_codex.sh "实现请求的改动"
```

指定工作区和入口文件：

```bash
~/.agents/skills/codex/scripts/ask_codex.sh "重构这些组件并完成验证" \
  --workspace "/path/to/repo" \
  --file "src/components/UserList.tsx" \
  --file "src/components/UserDetail.tsx"
```

只读探索或评审：

```bash
~/.agents/skills/codex/scripts/ask_codex.sh "追踪当前请求路径并引用文件和行号" \
  --workspace "/path/to/repo" \
  --read-only
```

继续已有会话：

```bash
~/.agents/skills/codex/scripts/ask_codex.sh "继续修复刚才发现的问题" \
  --session <session_id>
```

使用默认 Codex 时，附加图片并要求结构化结果：

```bash
~/.agents/skills/codex/scripts/ask_codex.sh "比较截图与当前实现" \
  --image "/path/to/screenshot.png" \
  --output-schema "/path/to/result.schema.json" \
  --read-only
```

## 工作流程

1. 读取足够的本地上下文，明确目标和重要限制。
2. 根据任务选择只读或工作区写入权限。
3. 使用包装脚本派发一段聚焦的提示词，通常控制在 500 字以内。
4. 读取脚本返回的 `output_path`。
5. 先检查测试是否被删除、跳过或弱化，再检查工作区改动是否越界。
6. 重新运行真实验证命令；Codex 的“测试通过”只是报告，不能替代调用方验收。
7. 检查硬编码成功结果、吞掉异常、未经确认的 API、死代码和无调用方的抽象。
8. 需要返工时继续原会话，只发送新发现和修正要求，不重复整个任务。

分析、讨论、探索和评审任务使用 `--read-only`。实现任务默认使用 `workspace-write`。一次性测试可以使用 `--ephemeral`。

## 思考强度

正常调用不要传 `--reasoning`，由运行环境使用默认的 `high`。只有确实需要改变默认行为时才指定：

- `high`：默认档位，适合绝大多数编码、探索、实现和评审任务；无需显式传递。
- `max`：仅用于跨模块架构、疑难故障、复杂安全评审，或 `high` 已尝试但结论仍明显不足的任务。
- `low`：仅当用户明确优先考虑速度或成本，并且任务是简单、机械、低风险操作时使用。

DeepSeek V4 Flash 只支持 `low`、`high` 和 `max`。DeepSeek 运行环境启用时，不要传递 `medium`、`xhigh`、`minimal` 或 `ultra`。不要仅因为任务描述较长就自动使用 `max`；先收窄目标和上下文。

## 输出

成功后脚本输出：

```text
session_id=<thread_id>
runtime=<default|deepseek>
output_path=<path>
result_path=<path>
events_path=<path>
elapsed=<seconds>s
```

Markdown 结果包含：

- `## Summary`：Codex 的最终结论。
- `## Details`：有意义的命令、写入、补丁和中间消息；纯读取与搜索会被省略。
- 耗时、命令数和可用的 token 使用信息。

使用 `--output-schema` 时，`Summary` 包含符合指定 JSON Schema 的结果。

每次运行使用独立目录，避免并行任务覆盖结果。`result_path` 是原子写入的结构化状态，包含 `completed` 或 `failed`、退出码、运行环境、会话 ID、最终消息、耗时及错误尾部；`events_path` 保留原始 JSONL，便于失败诊断和恢复。调用方平时只需读取 `output_path`，出现异常时再读取另外两个文件。

## 图片

`--image` 只用于默认 Codex 运行环境。DeepSeek V4 Flash 当前没有视觉识别能力；若已经配置 DeepSeek，应由调用 Skill 的 Agent 自己查看图片，并把页面结构、文字、颜色、尺寸和异常点等必要视觉信息写进委托提示词。包装脚本会拒绝把图片发送给 DeepSeek，避免静默得到错误结果。

需要透明背景图片时：

1. 先明确要求生成透明背景 PNG。
2. 指定最终输出路径，并要求 Codex 报告该路径。
3. 只有原生透明效果不可靠时，才使用灰底抠图工具：

```bash
python3 ~/.agents/skills/codex/scripts/cutout.py input.png output.png
```

使用该后备方案时，让图像生成在纯 `#808080` 背景上，执行抠图后确认输出为 RGBA，并检查边缘质量。

## 对外参数

- `--workspace <path>`：工作目录，默认使用当前目录。
- `--file <path>`：优先入口文件，可重复使用。
- `--image <path>`：附加图片，可重复使用。
- `--session <id>`：继续已有会话。
- `--reasoning <low|high|max>`：特殊情况下覆盖默认思考强度，常规调用不要传递。
- `--sandbox <mode>`：覆盖新会话的沙箱模式。
- `--read-only`：只读新会话。
- `--full-auto`：使用默认的工作区写入模式。
- `--ephemeral`：不持久化会话。
- `--output-schema <path>`：约束最终输出结构。
- `--notify`：长任务结束后发送通知。
- `--output <path>`：指定 Markdown 结果路径。

## 会话约束

续接会话会保留原工作区上下文和权限，因此不要把 `--read-only` 或 `--sandbox` 与 `--session` 同时使用。DeepSeek 配置启用后，会话文件位于独立的 `~/.codex-deepseek`；继续会话时应保持该运行环境可用。

## 失败处理

- 非零退出码、`turn.failed` 或明确错误事件都视为失败。
- 失败运行也会输出 `result_path` 与 `events_path`；先读取结构化错误和事件尾部，再决定缩小任务、修正配置或续接会话。
- 退出码 137 通常表示进程被中断或终止；先检查资源压力或缩小任务范围，再决定是否重试。
- Skill 或插件加载警告通常不影响任务，除非 Codex 回合本身失败。
- Bash 包装脚本会检测 PTY 支持；不支持时回退到直接执行，任务仍可完成，但进度可能集中在结束时返回。
