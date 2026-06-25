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

    [string]$Session,

    [string]$Model,

    [ValidateSet('low', 'medium', 'high')]
    [string]$Reasoning = 'medium',

    [string]$Sandbox,

    [switch]$ReadOnly,

    [switch]$FullAuto,

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

Multi-turn:
  -Session <id>                Resume a previous session (thread_id from prior run)

Options:
  -Workspace, -w <path>        Workspace directory (default: current directory)
  -Model <name>                Model override
  -Reasoning <level>           Reasoning effort: low, medium, high (default: medium)
  -Sandbox <mode>              Sandbox mode override
  -ReadOnly                    Read-only sandbox (no file changes)
  -FullAuto                    Full-auto mode (default)
  -Notify                      Desktop notification when a long run finishes (opt-in)
  -Output, -o <path>           Output file path
  -Help                        Show this help

Output (on success):
  session_id=<thread_id>       Use with -Session for follow-up calls
  output_path=<file>           Path to response markdown

Examples:
  # New task (positional)
  ask_codex.ps1 "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_codex.ps1 "Fix the bug" -w C:\other\repo

  # Continue conversation
  ask_codex.ps1 "Also add retry logic" -Session <id>
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
    return $Text.Trim() -replace '\s+', ' '
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

# Validate task
$Task = Trim-Whitespace $Task
if ([string]::IsNullOrEmpty($Task)) {
    Write-Error "[ERROR] Request text is empty. Pass a positional arg or -Task."
    exit 1
}

# Prepare output path
if ([string]::IsNullOrEmpty($Output)) {
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $skillDir = Split-Path $PSScriptRoot -Parent
    $runtimeDir = Join-Path $skillDir '.runtime'
    if (-not (Test-Path $runtimeDir)) {
        New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }
    $Output = Join-Path $runtimeDir "$timestamp.md"
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

if (-not [string]::IsNullOrEmpty($Session)) {
    # Resume mode: continue a previous session
    # Note: resume only supports -c/--config and --last flags (no --json, --sandbox, etc.)
    $codexArgs = @('exec', 'resume', '-c', "model_reasoning_effort=`"$Reasoning`"", '-c', 'skip_git_repo_check=true')
    $codexArgs += $Session
} else {
    # New session
    $codexArgs = @('exec', '--cd', $Workspace, '--skip-git-repo-check', '--json', '-c', "model_reasoning_effort=`"$Reasoning`"")
    if ($ReadOnly) {
        $codexArgs += '--sandbox', 'read-only'
    } elseif (-not [string]::IsNullOrEmpty($Sandbox)) {
        $codexArgs += '--sandbox', $Sandbox
    } elseif ($FullAuto) {
        $codexArgs += '--full-auto'
    }
    if (-not [string]::IsNullOrEmpty($Model)) {
        $codexArgs += '-m', $Model
    }
}

# Create temp files
$tempDir = [System.IO.Path]::GetTempPath()
$guid = [guid]::NewGuid().ToString()
$stderrFile = Join-Path $tempDir "codex_stderr_$guid.txt"
$jsonFile = Join-Path $tempDir "codex_json_$guid.txt"
$promptFile = Join-Path $tempDir "codex_prompt_$guid.txt"

# Cleanup function
$cleanupScript = {
    Remove-Item -Path $stderrFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $jsonFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $promptFile -Force -ErrorAction SilentlyContinue
}

try {
    # Write prompt to temp file (UTF-8 without BOM)
    Write-File-NoBOM -Path $promptFile -Content $prompt

    # Initialize json file
    Write-File-NoBOM -Path $jsonFile -Content ''

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
    $outputLock = New-Object Object

    # Event handler script blocks
    $jsonOutputRef = $jsonOutput
    $stderrOutputRef = $stderrOutput

    # Register event handlers for async reading
    $isResumeMode = -not [string]::IsNullOrEmpty($Session)
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

    if ($isResumeMode) {
        # Resume mode: plain text output (no JSON structure to summarize)
        $textContent = $textOutput.ToString().Trim()

        # Check for errors
        $stderrText = $stderrOutput.ToString()
        $hasValidOutput = -not [string]::IsNullOrWhiteSpace($textContent)

        if ($stderrText -match '\[ERROR\]' -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex command failed"
            Write-Error $stderrText
            exit 1
        }

        if ($exitCode -ne 0 -and -not $hasValidOutput) {
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
        Write-File-NoBOM -Path $jsonFile -Content $jsonText

        # Check for errors - but only fail if no valid output was received
        $stderrText = $stderrOutput.ToString()
        $hasValidOutput = -not [string]::IsNullOrWhiteSpace($jsonText) -and $jsonText -match '"thread_id"'

        if ($stderrText -match '\[ERROR\]' -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex command failed"
            Write-Error $stderrText
            exit 1
        }

        if ($exitCode -ne 0 -and -not $hasValidOutput) {
            Write-Error "[ERROR] Codex exited with code $exitCode"
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
    Write-Output "output_path=$Output"
    Write-Output "elapsed=${elapsed}s"

} finally {
    & $cleanupScript
}
