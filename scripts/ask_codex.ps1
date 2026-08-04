#!/usr/bin/env powershell
# Windows PowerShell 5.1+ compatible script
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Task,

    [Alias('t')]
    [string]$TaskText,

    [Alias('w')]
    [string]$Workspace = (Get-Location).Path,

    [Alias('f')]
    [string[]]$File,

    [Alias('i')]
    [string[]]$Image,

    [string]$Session,

    [string]$Model,

    [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max')]
    [string]$Reasoning = 'high',

    [switch]$Fast,

    [string]$Sandbox,

    [switch]$ReadOnly,

    [switch]$FullAuto,

    [switch]$Ephemeral,

    [string]$OutputSchema,

    [switch]$Notify,

    [Alias('o')]
    [string]$Output,

    [switch]$Help
)

$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
Usage:
  ask_codex.ps1 <task> [options]
  ask_codex.ps1 -Task <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -Task, -t <text>             Alias for positional task

File context (optional, repeatable):
  -File, -f <path>             Priority file path
  -Image, -i <path>            Image to attach to the default Codex runtime

Multi-turn:
  -Session <id>                Resume a previous session (thread_id from prior run)

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -Model <name>                Model override
  -Reasoning <level>           minimal, low, medium, high, xhigh, max (default: high)
  -Fast                        Use the Fast service tier (higher usage/cost)
  -Sandbox <mode>              Sandbox mode override
  -ReadOnly                    Read-only sandbox (no file changes)
  -FullAuto                    Compatibility alias for workspace-write (default)
  -Ephemeral                   Do not persist the Codex session
  -OutputSchema <path>         Require the final response to match a JSON Schema
  -Notify                      Desktop notification when a long run finishes (opt-in)
  -Output, -o <path>           Output file path
  -Help                        Show this help

Output (on success):
  session_id=<thread_id>       Use with -Session for follow-up calls
  runtime=<default|deepseek>   Automatically selected Codex runtime
  output_path=<file>           Path to response markdown
  result_path=<file>           Structured run status and metadata
  events_path=<file>           Raw Codex JSONL events for diagnostics

Examples:
  # New task (positional)
  ask_codex.ps1 "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex.ps1 "Fix the bug" -w C:\other\repo

  # Continue conversation
  ask_codex.ps1 "Also add retry logic" -Session <id>

  # Read-only structured analysis with an attached image (default runtime only)
  ask_codex.ps1 "Compare screenshot and implementation" -ReadOnly `
    -Image screenshot.png -OutputSchema result.schema.json
'@
}

function Test-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Error "[ERROR] Missing required command: $Name"
        exit 1
    }
}

function Trim-Whitespace {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return $Text.Trim()
}

function Initialize-CodexRuntime {
    $script:SelectedRuntime = 'default'
    $userHome = [Environment]::GetFolderPath('UserProfile')
    $deepSeekHome = if ($env:CODEX_DEEPSEEK_HOME) {
        $env:CODEX_DEEPSEEK_HOME
    } else {
        Join-Path $userHome '.codex-deepseek'
    }
    $configPath = Join-Path $deepSeekHome 'config.toml'

    if (-not (Test-Path $configPath -PathType Leaf)) {
        if ($env:CODEX_DEEPSEEK_HOME) {
            Write-Error "[ERROR] CODEX_DEEPSEEK_HOME is set but config.toml is missing: $configPath"
            exit 1
        }
        return
    }

    $modelsPath = Join-Path $deepSeekHome 'models.json'
    if (-not (Test-Path $modelsPath -PathType Leaf)) {
        Write-Error "[ERROR] DeepSeek Codex is configured but models.json is missing: $modelsPath"
        exit 1
    }

    $env:CODEX_HOME = $deepSeekHome
    $script:SelectedRuntime = 'deepseek'

    if (-not $env:DEEPSEEK_API_KEY -and (Get-Command security -ErrorAction SilentlyContinue)) {
        $account = [Environment]::UserName
        $key = (& security find-generic-password -a $account -s codex-deepseek-api-key -w 2>$null)
        if ($key) { $env:DEEPSEEK_API_KEY = $key.Trim() }
    }

    if (-not $env:DEEPSEEK_API_KEY) {
        Write-Error '[ERROR] DeepSeek Codex is configured but DEEPSEEK_API_KEY is unavailable.'
        exit 1
    }
}

function Resolve-FileRef {
    param(
        [string]$Workspace,
        [string]$RawPath
    )

    $cleaned = Trim-Whitespace $RawPath
    if ([string]::IsNullOrWhiteSpace($cleaned)) { return '' }

    # Remove line number suffixes (#L123 or :123-456)
    $cleaned = $cleaned -replace '#L\d+$', ''
    $cleaned = $cleaned -replace ':\d+(-\d+)?$', ''

    # Make absolute if relative
    if (-not [System.IO.Path]::IsPathRooted($cleaned)) {
        $cleaned = Join-Path $Workspace $cleaned
    }

    # Normalize path
    if (Test-Path $cleaned) {
        return (Resolve-Path $cleaned -ErrorAction SilentlyContinue).Path
    }
    return $cleaned
}

function Write-File-NoBOM {
    param([string]$Path, [string]$Content)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Write-RunResult {
    param(
        [string]$Path,
        [string]$Status,
        [int]$ExitCode,
        [string]$Runtime,
        [string]$SessionId,
        [string]$FinalMessage,
        [string]$OutputPath,
        [string]$EventsPath,
        [string]$StderrPath,
        [int]$Elapsed,
        [string]$StartedAt,
        [string]$ErrorMessage
    )

    $stderrTail = $null
    if ($Status -ne 'completed' -and (Test-Path $StderrPath -PathType Leaf)) {
        $stderrTail = ((Get-Content $StderrPath -Tail 20 -ErrorAction SilentlyContinue) -join "`n").Trim()
        if ([string]::IsNullOrWhiteSpace($stderrTail)) { $stderrTail = $null }
    }

    $result = [ordered]@{
        schema = 'codex-skill.run.v1'
        status = $Status
        exit_code = $ExitCode
        runtime = $Runtime
        run_id = (Split-Path (Split-Path $Path -Parent) -Leaf)
        workspace = $script:RunWorkspace
        session_id = if ([string]::IsNullOrEmpty($SessionId)) { $null } else { $SessionId }
        final_message = if ($null -eq $FinalMessage) { '' } else { $FinalMessage }
        output_path = $OutputPath
        events_path = $EventsPath
        stderr_path = $StderrPath
        elapsed_seconds = $Elapsed
        started_at = $StartedAt
        finished_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        stderr_tail = $stderrTail
        error = if ([string]::IsNullOrEmpty($ErrorMessage)) { $null } else { $ErrorMessage }
    }

    $temporaryPath = "$Path.tmp.$PID"
    Write-File-NoBOM -Path $temporaryPath -Content ($result | ConvertTo-Json -Depth 5)
    Move-Item -Path $temporaryPath -Destination $Path -Force
}

function Send-Notification {
    # Best-effort desktop notification on Windows; never allowed to break the run.
    param([string]$Title, [string]$Body, [int]$Elapsed)
    $minSecs = if ($env:CODEX_NOTIFY_MIN_SECONDS) { [int]$env:CODEX_NOTIFY_MIN_SECONDS } else { 30 }
    if ($Elapsed -lt $minSecs) { return }
    try {
        if (Get-Command New-BurntToastNotification -ErrorAction SilentlyContinue) {
            New-BurntToastNotification -Text $Title, $Body -ErrorAction SilentlyContinue | Out-Null
            return
        }
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Information
        $ni.Visible = $true
        $ni.ShowBalloonTip(5000, $Title, $Body, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Milliseconds 250
        $ni.Dispose()
    } catch { }
}

# Show help if requested
if ($Help) {
    Show-Usage
    exit 0
}

# Check required commands
Test-Command 'codex'
Test-Command 'jq'
Initialize-CodexRuntime

# Resolve task text from either positional or named parameter
if ([string]::IsNullOrEmpty($Task) -and -not [string]::IsNullOrEmpty($TaskText)) {
    $Task = $TaskText
}

# Validate workspace
if (-not (Test-Path $Workspace -PathType Container)) {
    Write-Error "[ERROR] Workspace does not exist: $Workspace"
    exit 1
}
$Workspace = (Resolve-Path $Workspace).Path
$script:RunWorkspace = $Workspace

# Validate task
$Task = Trim-Whitespace $Task
if ([string]::IsNullOrEmpty($Task)) {
    Write-Error "[ERROR] Request text is empty. Pass a positional arg or -Task."
    exit 1
}

if ($script:SelectedRuntime -eq 'deepseek' -and $Reasoning -notin @('low', 'high', 'max')) {
    Write-Error '[ERROR] DeepSeek supports only low, high, and max reasoning. Omit -Reasoning to use high.'
    exit 1
}

if (-not [string]::IsNullOrEmpty($Session) -and ($ReadOnly -or $FullAuto -or -not [string]::IsNullOrEmpty($Sandbox))) {
    Write-Error "[ERROR] Codex resume cannot override sandbox mode; it keeps the original session permissions."
    exit 1
}

if (-not [string]::IsNullOrEmpty($OutputSchema)) {
    if (-not [System.IO.Path]::IsPathRooted($OutputSchema)) {
        $OutputSchema = Join-Path $Workspace $OutputSchema
    }
    if (-not (Test-Path $OutputSchema -PathType Leaf)) {
        Write-Error "[ERROR] Output schema not found: $OutputSchema"
        exit 1
    }
    $OutputSchema = (Resolve-Path $OutputSchema).Path
}

$resolvedImages = @()
if ($script:SelectedRuntime -eq 'deepseek' -and @($Image).Count -gt 0) {
    Write-Error '[ERROR] DeepSeek V4 Flash is text-only and cannot receive -Image. Inspect the image in the calling Agent, then pass the visual findings as text.'
    exit 1
}
foreach ($imagePath in @($Image)) {
    if ([string]::IsNullOrWhiteSpace($imagePath)) { continue }
    $resolvedImage = $imagePath
    if (-not [System.IO.Path]::IsPathRooted($resolvedImage)) {
        $resolvedImage = Join-Path $Workspace $resolvedImage
    }
    if (-not (Test-Path $resolvedImage -PathType Leaf)) {
        Write-Error "[ERROR] Image not found: $resolvedImage"
        exit 1
    }
    $resolvedImages += (Resolve-Path $resolvedImage).Path
}

# Prepare unique run artifacts
$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$runtimeDir = if ($env:CODEX_SKILL_STATE_HOME) {
    $env:CODEX_SKILL_STATE_HOME
} else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'codex-skill'
}
if (-not (Test-Path $runtimeDir)) {
    New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}
$runId = [guid]::NewGuid().ToString('N').Substring(0, 8)
$runDir = Join-Path $runtimeDir "run-$timestamp-$runId"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$resultPath = Join-Path $runDir 'result.json'
$eventsPath = Join-Path $runDir 'events.jsonl'
$stderrPath = Join-Path $runDir 'stderr.log'
if ([string]::IsNullOrEmpty($Output)) {
    $Output = Join-Path $runDir 'result.md'
}

# Build file context block
$fileBlock = ''
if ($File -and $File.Count -gt 0) {
    $fileBlock = "`nPriority files (read these first before making changes):"
    foreach ($ref in $File) {
        $resolved = Resolve-FileRef -Workspace $Workspace -RawPath $ref
        if (-not [string]::IsNullOrEmpty($resolved)) {
            $existsTag = if (Test-Path $resolved) { 'exists' } else { 'missing' }
            $fileBlock += "`n- $resolved ($existsTag)"
        }
    }
}

# Build prompt
$prompt = $Task
if (-not [string]::IsNullOrEmpty($fileBlock)) {
    $prompt += $fileBlock
}

# Build codex command
$codexArgs = @()
$commonArgs = @('--json', '--skip-git-repo-check', '-c', "model_reasoning_effort=`"$Reasoning`"")
if ($Fast) {
    $commonArgs += '-c', 'service_tier="fast"', '-c', 'features.fast_mode=true'
}

if (-not [string]::IsNullOrEmpty($Session)) {
    # Current Codex resume supports JSON, model/image/schema overrides, and non-git workspaces.
    $codexArgs = @('exec', 'resume') + $commonArgs
    if (-not [string]::IsNullOrEmpty($Model)) { $codexArgs += '-m', $Model }
    if ($Ephemeral) { $codexArgs += '--ephemeral' }
    if (-not [string]::IsNullOrEmpty($OutputSchema)) { $codexArgs += '--output-schema', $OutputSchema }
    foreach ($resolvedImage in $resolvedImages) { $codexArgs += '--image', $resolvedImage }
    $codexArgs += $Session, '-'
} else {
    # New session
    $codexArgs = @('exec', '--cd', $Workspace) + $commonArgs
    if ($ReadOnly) {
        $codexArgs += '--sandbox', 'read-only'
    } elseif (-not [string]::IsNullOrEmpty($Sandbox)) {
        $codexArgs += '--sandbox', $Sandbox
    } else {
        $codexArgs += '--sandbox', 'workspace-write'
    }
    if (-not [string]::IsNullOrEmpty($Model)) { $codexArgs += '-m', $Model }
    if ($Ephemeral) { $codexArgs += '--ephemeral' }
    if (-not [string]::IsNullOrEmpty($OutputSchema)) { $codexArgs += '--output-schema', $OutputSchema }
    foreach ($resolvedImage in $resolvedImages) { $codexArgs += '--image', $resolvedImage }
}

# Setup process with async reading for real-time output
    # On Windows, codex is installed as a .ps1 script, so we need to use cmd.exe or pwsh to run it
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    if ($IsWindows -or $PSVersionTable.PSVersion.Major -le 5) {
        # Use cmd.exe to run codex (works with .cmd/.ps1 wrappers)
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/c codex ' + ($codexArgs -join ' ')
    } else {
        $psi.FileName = 'codex'
        $psi.Arguments = $codexArgs -join ' '
    }
    $psi.WorkingDirectory = $Workspace
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    # StringBuilder for collecting output
    $jsonOutput = New-Object System.Text.StringBuilder
    $stderrOutput = New-Object System.Text.StringBuilder

    # Register event handlers for async reading
    # New and resumed sessions both use JSONL on current Codex CLI.
    $isResumeMode = $false
    $textOutput = New-Object System.Text.StringBuilder

    $stdOutAction = {
        param([object]$sender, [System.Diagnostics.DataReceivedEventArgs]$e)
        if ($e.Data) {
            $line = $e.Data
            # Strip terminal artifacts
            $line = $line -replace "`r", ''
            $line = $line -replace [char]4, ''

            if (-not [string]::IsNullOrEmpty($line)) {
                if ($line.StartsWith('{')) {
                    # JSON line (new session mode)
                    [System.Threading.Monitor]::Enter($Event.MessageData)
                    try {
                        $Event.MessageData.AppendLine($line) | Out-Null
                    } finally {
                        [System.Threading.Monitor]::Exit($Event.MessageData)
                    }

                    # Print progress for relevant events
                    if ($line -match '"item\.started"' -or $line -match '"item\.completed"') {
                        if ($line -match '"item\.started"' -and $line -match '"command_execution"') {
                            try {
                                $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                                $cmd = $json.item.command
                                if ($cmd) {
                                    $cmd = $cmd -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                                    if ($cmd.Length -gt 100) { $cmd = $cmd.Substring(0, 100) }
                                    Write-Host "[codex] > $cmd" -ForegroundColor Gray
                                }
                            } catch {}
                        }
                        if ($line -match '"item\.completed"' -and $line -match '"agent_message"') {
                            try {
                                $json = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                                $text = $json.item.text
                                if ($text) {
                                    $preview = $text.Split("`n")[0]
                                    if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                                    Write-Host "[codex] $preview" -ForegroundColor Gray
                                }
                            } catch {}
                        }
                    }
                } else {
                    # Plain text line (resume mode)
                    [System.Threading.Monitor]::Enter($Event.MessageData)
                    try {
                        $Event.MessageData.AppendLine($line) | Out-Null
                    } finally {
                        [System.Threading.Monitor]::Exit($Event.MessageData)
                    }
                    # Show progress for text output
                    $preview = $line
                    if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) }
                    Write-Host "[codex] $preview" -ForegroundColor Gray
                }
            }
        }
    }

    $stdErrAction = {
        param([object]$sender, [System.Diagnostics.DataReceivedEventArgs]$e)
        if ($e.Data) {
            [System.Threading.Monitor]::Enter($Event.MessageData)
            try {
                $Event.MessageData.AppendLine($e.Data) | Out-Null
            } finally {
                [System.Threading.Monitor]::Exit($Event.MessageData)
            }
            Write-Host $e.Data -ForegroundColor Yellow
        }
    }

    # Register events - use textOutput for resume mode, jsonOutput for new session
    $outputData = if ($isResumeMode) { $textOutput } else { $jsonOutput }
    $stdOutEvent = Register-ObjectEvent -InputObject $process -EventName OutputDataReceived -Action $stdOutAction -MessageData $outputData
    $stdErrEvent = Register-ObjectEvent -InputObject $process -EventName ErrorDataReceived -Action $stdErrAction -MessageData $stderrOutput

    $elapsed = 0
    try {
        # Start process
        $startTime = Get-Date
        $startedAt = $startTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $process.Start() | Out-Null

        # Begin async reading
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()

        # Write prompt to stdin
        $process.StandardInput.Write($prompt)
        $process.StandardInput.Close()

        # Wait for process to exit
        $process.WaitForExit()
        $exitCode = $process.ExitCode
        $elapsed = [int][Math]::Round(((Get-Date) - $startTime).TotalSeconds)

    } finally {
        # Unregister events
        Unregister-Event -SourceIdentifier $stdOutEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $stdErrEvent.Name -ErrorAction SilentlyContinue
        $process.Dispose()
    }

    # Process output based on mode
    $threadId = $null
    $finalOutput = ''
    $summaryText = ''
    # Commands Codex runs purely to read/search the codebase carry no signal for the
    # caller — skip them in the trace (they are still counted). Matches the bash script.
    $readOnlyCmdPattern = '^["'']?(sed |cat |head |tail |nl |rg |grep |awk |wc |find |ls )'

    $capturedJson = $jsonOutput.ToString()
    $capturedStderr = $stderrOutput.ToString()
    Write-File-NoBOM -Path $eventsPath -Content $capturedJson
    Write-File-NoBOM -Path $stderrPath -Content $capturedStderr

    if ($isResumeMode) {
        # Resume mode: plain text output (no JSON structure to summarize)
        $textContent = $textOutput.ToString().Trim()

        # Check for errors
        $stderrText = $stderrOutput.ToString()
        $hasValidOutput = -not [string]::IsNullOrWhiteSpace($textContent)

        if ($stderrText -match '\[ERROR\]' -and -not $hasValidOutput) {
            Write-RunResult -Path $resultPath -Status 'failed' -ExitCode 1 `
                -Runtime $script:SelectedRuntime -SessionId $Session -FinalMessage '' `
                -OutputPath $Output -EventsPath $eventsPath -StderrPath $stderrPath `
                -Elapsed $elapsed -StartedAt $startedAt -ErrorMessage 'Codex command failed'
            Write-Output "status=failed"
            Write-Output "runtime=$script:SelectedRuntime"
            Write-Output "session_id=$Session"
            Write-Output "result_path=$resultPath"
            Write-Output "events_path=$eventsPath"
            Write-Error "[ERROR] Codex command failed"
            Write-Error $stderrText
            exit 1
        }

        if ($exitCode -ne 0 -and -not $hasValidOutput) {
            Write-RunResult -Path $resultPath -Status 'failed' -ExitCode $exitCode `
                -Runtime $script:SelectedRuntime -SessionId $Session -FinalMessage '' `
                -OutputPath $Output -EventsPath $eventsPath -StderrPath $stderrPath `
                -Elapsed $elapsed -StartedAt $startedAt -ErrorMessage "Codex exited with code $exitCode"
            Write-Output "status=failed"
            Write-Output "runtime=$script:SelectedRuntime"
            Write-Output "session_id=$Session"
            Write-Output "result_path=$resultPath"
            Write-Output "events_path=$eventsPath"
            Write-Error "[ERROR] Codex exited with code $exitCode"
            exit 1
        }

        # Use session ID from parameter
        $threadId = $Session
        if ($hasValidOutput) {
            $finalOutput = $textContent
            $summaryText = $textContent
        }
    } else {
        # New session mode: JSON output
        $jsonText = $jsonOutput.ToString()

        if ($jsonText -match '"thread_id"\s*:\s*"([^"]+)"') {
            $threadId = $matches[1]
        } elseif ($jsonText -match '"threadId"\s*:\s*"([^"]+)"') {
            $threadId = $matches[1]
        } elseif (-not [string]::IsNullOrEmpty($Session)) {
            $threadId = $Session
        }

        # A started thread is not proof of success; turn.failed must propagate.
        $stderrText = $stderrOutput.ToString()
        $turnFailed = $jsonText -match '"type"\s*:\s*"turn.failed"'

        if ($turnFailed -or $exitCode -ne 0) {
            $resultExitCode = if ($exitCode -eq 0) { 1 } else { $exitCode }
            Write-RunResult -Path $resultPath -Status 'failed' -ExitCode $resultExitCode `
                -Runtime $script:SelectedRuntime -SessionId $threadId -FinalMessage '' `
                -OutputPath $Output -EventsPath $eventsPath -StderrPath $stderrPath `
                -Elapsed $elapsed -StartedAt $startedAt -ErrorMessage 'Codex command failed'
            Write-Output "status=failed"
            Write-Output "runtime=$script:SelectedRuntime"
            if (-not [string]::IsNullOrEmpty($threadId)) { Write-Output "session_id=$threadId" }
            Write-Output "result_path=$resultPath"
            Write-Output "events_path=$eventsPath"
            Write-Error "[ERROR] Codex command failed"
            if (-not [string]::IsNullOrWhiteSpace($stderrText)) { Write-Error $stderrText }
            exit 1
        }

        $agentMessages = @()
        $detailItems = @()
        $cmdCount = 0
        $usage = $null

        # Extract thread_id and messages from JSON stream
        if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
            # Find thread_id
            if ($jsonText -match '"thread_id"\s*:\s*"([^"]+)"') {
                $threadId = $matches[1]
            }
            if ([string]::IsNullOrEmpty($threadId) -and -not [string]::IsNullOrEmpty($Session)) {
                $threadId = $Session
            }

            # Parse JSON lines using PowerShell native parsing (more reliable on Windows)
            $jsonLines = $jsonText -split "`n" | Where-Object { $_.Trim() -and $_.TrimStart().StartsWith('{') }

            foreach ($line in $jsonLines) {
                try {
                    $obj = $line | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if (-not $obj) { continue }

                    # Token usage from the turn.completed event
                    if ($obj.type -eq 'turn.completed' -and $obj.usage) {
                        $usage = $obj.usage
                        continue
                    }

                    # Process completed items
                    if ($obj.type -eq 'item.completed' -and $obj.item) {
                        $item = $obj.item

                        # Agent messages (collected; the last one becomes the summary)
                        if ($item.type -eq 'agent_message' -and $item.text) {
                            $agentMessages += $item.text
                        }

                        # Command executions (count all; skip pure read/search ones in the trace)
                        if ($item.type -eq 'command_execution' -and $item.command) {
                            $cmdCount++
                            $cmd = $item.command -replace '^/bin/(zsh|bash) (-lc|-c) ', ''
                            if ($cmd -notmatch $readOnlyCmdPattern) {
                                $cmdPreview = $cmd.Substring(0, [Math]::Min(200, $cmd.Length))
                                $outPreview = ''
                                if ($item.aggregated_output) {
                                    $outPreview = $item.aggregated_output.Substring(0, [Math]::Min(800, $item.aggregated_output.Length))
                                }
                                $detailItems += "### Shell: ``$cmdPreview```n$outPreview"
                            }
                        }

                        # Tool calls (file operations)
                        if ($item.type -eq 'tool_call' -and $item.name) {
                            $toolArgs = $null
                            try {
                                $toolArgs = $item.arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
                            } catch {}

                            if ($item.name -eq 'write_file' -and $toolArgs.path) {
                                $detailItems += "### File written: $($toolArgs.path)"
                            }
                            if ($item.name -eq 'patch_file' -and $toolArgs.path) {
                                $detailItems += "### File patched: $($toolArgs.path)"
                            }
                            if ($item.name -eq 'shell' -and $toolArgs.command) {
                                $cmdPreview = $toolArgs.command.Substring(0, [Math]::Min(200, $toolArgs.command.Length))
                                $outPreview = ''
                                if ($item.output) {
                                    $outPreview = $item.output.Substring(0, [Math]::Min(800, $item.output.Length))
                                }
                                $detailItems += "### Shell: ``$cmdPreview```n$outPreview"
                            }
                        }
                    }
                } catch {
                    # Skip malformed lines
                }
            }
        }

        # Codex's final message is its own summary — surface it first. Earlier agent
        # messages are intermediate narration and go into the details.
        if ($agentMessages.Count -gt 0) { $summaryText = $agentMessages[-1] }
        if ($agentMessages.Count -gt 1) {
            $detailItems += $agentMessages[0..($agentMessages.Count - 2)]
        }

        $sections = @()
        if (-not [string]::IsNullOrWhiteSpace($summaryText)) {
            $sections += "## Summary`n`n$summaryText"
        }
        if ($detailItems.Count -gt 0) {
            $sections += "## Details`n`n" + ($detailItems -join "`n`n")
        }
        $footer = "---`nelapsed ${elapsed}s - $cmdCount cmds"
        if ($usage) {
            $footer += " - tokens in=$($usage.input_tokens) (cached $($usage.cached_input_tokens)) out=$($usage.output_tokens) reasoning=$($usage.reasoning_output_tokens)"
        }
        $sections += $footer
        $finalOutput = $sections -join "`n`n"
    }

    # Ensure output directory exists
    $outputDir = Split-Path $Output -Parent
    if (-not (Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Write output
    if (-not [string]::IsNullOrWhiteSpace($finalOutput)) {
        Write-File-NoBOM -Path $Output -Content $finalOutput
    } else {
        Write-File-NoBOM -Path $Output -Content "(no response from codex)"
    }

    Write-RunResult -Path $resultPath -Status 'completed' -ExitCode 0 `
        -Runtime $script:SelectedRuntime -SessionId $threadId -FinalMessage $summaryText `
        -OutputPath $Output -EventsPath $eventsPath -StderrPath $stderrPath `
        -Elapsed $elapsed -StartedAt $startedAt -ErrorMessage ''

    # Desktop notification for long runs (opt-in via -Notify or CODEX_NOTIFY=1)
    if ($Notify -or $env:CODEX_NOTIFY -eq '1') {
        $bodyPreview = if (-not [string]::IsNullOrWhiteSpace($summaryText)) { $summaryText } else { 'task complete' }
        $bodyPreview = ($bodyPreview -replace "`n", ' ')
        if ($bodyPreview.Length -gt 120) { $bodyPreview = $bodyPreview.Substring(0, 120) }
        Send-Notification -Title "Codex done (${elapsed}s)" -Body $bodyPreview -Elapsed $elapsed
    }

    # Output results
    if (-not [string]::IsNullOrEmpty($threadId)) {
        Write-Output "session_id=$threadId"
    }
    Write-Output "runtime=$script:SelectedRuntime"
    Write-Output "output_path=$Output"
    Write-Output "result_path=$resultPath"
    Write-Output "events_path=$eventsPath"
    Write-Output "elapsed=${elapsed}s"
