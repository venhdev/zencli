# Confirmed command audit log manager & rerun helpers for Windows PowerShell (cmdlog, clog, cr)

function _cmdlog_file {
    if ($env:CMD_LOG) {
        return $env:CMD_LOG
    }
    $stateDir = if ($env:ZEN_STATE_DIR) { $env:ZEN_STATE_DIR } else { "$env:LOCALAPPDATA\zen" }
    $legacyDir = "$env:LOCALAPPDATA\dotfiles"
    if (Test-Path $legacyDir) {
        if (!(Test-Path $stateDir)) {
            New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
        }
        if ((Test-Path "$legacyDir\commands.log") -and !(Test-Path "$stateDir\commands.log")) {
            Move-Item -Path "$legacyDir\commands.log" -Destination "$stateDir\commands.log" -Force -ErrorAction SilentlyContinue
        } elseif ((Test-Path "$legacyDir\commands.log") -and (Test-Path "$stateDir\commands.log")) {
            Get-Content "$legacyDir\commands.log" | Add-Content "$stateDir\commands.log" -ErrorAction SilentlyContinue
            Remove-Item -Path "$legacyDir\commands.log" -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -Path $legacyDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (!(Test-Path $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    return "$stateDir\commands.log"
}

function _cmdlog_parse_records {
    param([string]$FilePath)
    if (!(Test-Path $FilePath)) { return @() }

    $lines = Get-Content -Path $FilePath -ErrorAction SilentlyContinue
    if (-not $lines) { return @() }

    # Parse in reverse (latest first)
    [Array]::Reverse($lines)

    $records = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($line in $lines) {
        if ($line -match '^\[([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2})\](.*)$') {
            $ts = $Matches[1]
            $rest = $Matches[2]
            $status = "-"
            $dur = "-"
            $cwd = "-"
            $cmd = ""

            if ($rest -match '\[status:([^]]*)\]') { $status = $Matches[1] }
            if ($rest -match '\[dur:([^]]*)\]') { $dur = $Matches[1] }
            if ($rest -match '\[cwd:([^]]*)\]') { $cwd = $Matches[1] }

            if ($rest -like "* ▶ *") {
                $cmd = $rest.Substring($rest.IndexOf(" ▶ ") + 3).Trim()
            } else {
                $cmd = $rest.Trim()
            }

            if (-not [string]::IsNullOrWhiteSpace($cmd)) {
                $records.Add([PSCustomObject]@{
                    Timestamp = $ts
                    Status    = $status
                    Duration  = $dur
                    Cwd       = $cwd
                    Command   = $cmd
                })
            }
        }
    }
    return $records
}

function _cmdlog_help {
    Write-Host @"
cmdlog / clog - Confirmed Command Audit Log & Rerun (PowerShell)

Usage:
  clog [query] [limit]    View recent confirmed commands (default: 10)
  clog -d [limit]         View commands executed in current directory ($PWD)
  clog -a / all           View full command history
  clog path               Print path to commands.log
  clog clean [--keep N]   Truncate log keeping latest N entries (default: 500)
  clog clip [index]       Copy command to clipboard (default: latest)

  cr [query|index]        Interactive picker or direct rerun by index
  cr -d [query]           Rerun scoped to current directory ($PWD)

Shortcuts:
  clog -> cmdlog
  cr   -> cmdlog run
"@
}

function _cmdlog_list {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $records = _cmdlog_parse_records -FilePath $FilePath
    if ($records.Count -eq 0) {
        Write-Host "No command history logged yet." -ForegroundColor DarkGray
        return
    }

    $limit = 10
    $cwdOnly = $false
    $query = ""

    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $arg = $Arguments[$i]
        switch -Regex ($arg) {
            '^(-d|--cwd|\.)$' { $cwdOnly = $true }
            '^(-a|--all|all)$' { $limit = 999999 }
            '^[0-9]+$' { $limit = [int]$arg }
            default { $query = if ($query) { "$query $arg" } else { $arg } }
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $records) {
        $matchCwd = (-not $cwdOnly) -or ($entry.Cwd -eq (Get-Location).Path)
        $matchQuery = (-not $query) -or ($entry.Command -like "*$query*")
        if ($matchCwd -and $matchQuery) {
            if ($seen.Add($entry.Command)) {
                $items.Add($entry)
                if ($items.Count -ge $limit) { break }
            }
        }
    }

    if ($items.Count -eq 0) {
        Write-Host "No matching commands found." -ForegroundColor DarkGray
        return
    }

    $maxCols = 80
    try { $maxCols = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($maxCols -le 20) { $maxCols = 80 }

    for ($idx = 0; $idx -lt $items.Count; $idx++) {
        $entry = $items[$idx]
        $stColor = switch ($entry.Status) {
            "0" { "Green" }
            "-" { "DarkGray" }
            default { "Red" }
        }
        Write-Host (" [{0}] " -f ($idx + 1)) -NoNewline -ForegroundColor Cyan
        Write-Host "$($entry.Timestamp) " -NoNewline -ForegroundColor DarkGray
        Write-Host ("[{0}] " -f $entry.Status) -NoNewline -ForegroundColor $stColor
        if ($entry.Cwd -ne "-" -and $entry.Cwd) {
            Write-Host ("[{0}]" -f (Split-Path -Leaf $entry.Cwd)) -NoNewline -ForegroundColor Yellow
        }
        Write-Host ""
        $dispCmd = $entry.Command
        if ($dispCmd.Length -gt ($maxCols - 2)) {
            $dispCmd = $dispCmd.Substring(0, $maxCols - 5) + "..."
        }
        Write-Host $dispCmd
        if ($idx -lt $items.Count - 1) {
            Write-Host ""
        }
    }
}

function _cmdlog_run {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )
    $records = _cmdlog_parse_records -FilePath $FilePath
    if ($records.Count -eq 0) {
        Write-Warning "No commands found in log."
        return
    }

    $targetIdx = $null
    $query = ""
    $cwdOnly = $false

    foreach ($arg in $Arguments) {
        if ($arg -match '^(-d|--cwd|\.)$') {
            $cwdOnly = $true
        } elseif ($arg -match '^[0-9]+$' -and -not $targetIdx) {
            $targetIdx = [int]$arg
        } else {
            $query = if ($query) { "$query $arg" } else { $arg }
        }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $filtered = [System.Collections.Generic.List[object]]::new()
    foreach ($rec in $records) {
        $matchCwd = (-not $cwdOnly) -or ($rec.Cwd -eq (Get-Location).Path)
        $matchQuery = (-not $query) -or ($rec.Command -like "*$query*")
        if ($matchCwd -and $matchQuery) {
            if ($seen.Add($rec.Command)) {
                $filtered.Add($rec)
                if ($filtered.Count -ge 10) { break }
            }
        }
    }

    if ($filtered.Count -eq 0) {
        Write-Warning "No matching commands found."
        return
    }

    $maxCols = 80
    try { $maxCols = $Host.UI.RawUI.WindowSize.Width } catch {}
    if ($maxCols -le 20) { $maxCols = 80 }

    $chosenCmd = $null
    $isInteractive = $false
    if ($targetIdx) {
        if ($targetIdx -ge 1 -and $targetIdx -le $filtered.Count) {
            $chosenCmd = $filtered[$targetIdx - 1].Command
        } else {
            Write-Error "Invalid index $targetIdx (must be 1-$($filtered.Count))."
            return
        }
    } else {
        $isInteractive = $true
        # Check if Out-ConsoleGridView is available
        if (Get-Command Out-ConsoleGridView -ErrorAction SilentlyContinue) {
            $selected = $filtered | Out-ConsoleGridView -Title "Select Command to Rerun" -OutputMode Single
            if ($selected) { $chosenCmd = $selected.Command }
        } else {
            for ($i = 0; $i -lt $filtered.Count; $i++) {
                $stColor = switch ($filtered[$i].Status) {
                    "0" { "Green" }
                    "-" { "DarkGray" }
                    default { "Red" }
                }
                Write-Host (" [{0}] " -f ($i + 1)) -NoNewline -ForegroundColor Cyan
                Write-Host "$($filtered[$i].Timestamp) " -NoNewline -ForegroundColor DarkGray
                Write-Host ("[{0}] " -f $filtered[$i].Status) -NoNewline -ForegroundColor $stColor
                if ($filtered[$i].Cwd -ne "-" -and $filtered[$i].Cwd) {
                    Write-Host ("[{0}]" -f (Split-Path -Leaf $filtered[$i].Cwd)) -NoNewline -ForegroundColor Yellow
                }
                Write-Host ""
                $dispCmd = $filtered[$i].Command
                if ($dispCmd.Length -gt ($maxCols - 2)) {
                    $dispCmd = $dispCmd.Substring(0, $maxCols - 5) + "..."
                }
                Write-Host $dispCmd
                if ($i -lt $filtered.Count - 1) {
                    Write-Host ""
                }
            }
            $choice = Read-Host "Select [1-$($filtered.Count), default 1, c <num> to copy, q to cancel]"
            if ($choice -eq "q" -or $choice -eq "0") { return }
            if ($choice -match '^(c|clip|copy)\s*(\d*)$') {
                $cIdx = if ($Matches[2]) { [int]$Matches[2] } else { 1 }
                if ($cIdx -ge 1 -and $cIdx -le $filtered.Count) {
                    $cmdToCopy = $filtered[$cIdx - 1].Command
                    Set-Clipboard -Value $cmdToCopy
                    Write-Host "✓ Copied to clipboard: $cmdToCopy" -ForegroundColor Green
                    return
                } else {
                    Write-Error "Invalid copy index $cIdx (must be 1-$($filtered.Count))."
                    return
                }
            }
            $pickIdx = if ([string]::IsNullOrWhiteSpace($choice)) { 1 } else { [int]$choice }
            if ($pickIdx -ge 1 -and $pickIdx -le $filtered.Count) {
                $chosenCmd = $filtered[$pickIdx - 1].Command
            }
        }
    }

    if (-not $chosenCmd) { return }

    if ($isInteractive) {
        $confirm = Read-Host "Execute: $chosenCmd? [Y/n]"
        if ($confirm -match '^(n|no)$') {
            Write-Host "Cancelled"
            return
        }
    }

    Write-Host "`n▶ $chosenCmd`n" -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $rc = 0
    try {
        $global:LASTEXITCODE = 0
        Invoke-Expression $chosenCmd
        $rc = if (-not $?) { 1 } elseif ($LASTEXITCODE -ne $null -and $LASTEXITCODE -ne 0) { $LASTEXITCODE } else { 0 }
    } catch {
        Write-Error $_
        $rc = 1
    } finally {
        $sw.Stop()
        $durSec = [Math]::Round($sw.Elapsed.TotalSeconds)
        $logLine = "[{0:yyyy-MM-dd HH:mm:ss}] [status:{1}] [dur:{2}s] [cwd:{3}] ▶ {4}" -f (Get-Date), $rc, $durSec, (Get-Location).Path, $chosenCmd
        Add-Content -Path $FilePath -Value $logLine -ErrorAction SilentlyContinue
    }
}

function cmdlog {
    param(
        [Parameter(Position = 0)]
        [string]$SubCommand = "",
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$RemainingArgs
    )
    $file = _cmdlog_file

    switch ($SubCommand) {
        "path" { $file }
        { $_ -in "help", "--help", "-h" } { _cmdlog_help }
        "clip" {
            $records = _cmdlog_parse_records -FilePath $file
            if ($records.Count -gt 0) {
                Set-Clipboard -Value $records[0].Command
                Write-Host "Copied: $($records[0].Command)" -ForegroundColor Green
            }
        }
        "run" {
            _cmdlog_run -FilePath $file -Arguments $RemainingArgs
        }
        default {
            $allArgs = @()
            if ($SubCommand) { $allArgs += $SubCommand }
            if ($RemainingArgs) { $allArgs += $RemainingArgs }
            _cmdlog_list -FilePath $file -Arguments $allArgs
        }
    }
}

function clog { cmdlog @args }
function cr   { cmdlog run @args }
