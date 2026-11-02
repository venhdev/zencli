# Cross-platform shims for Windows PowerShell (clip, open, zen, sudo)

# Detect Windows Host Environment (supports both PowerShell 5.1 Desktop and PowerShell Core 7+)
$global:IsWindowsHost = ($PSEdition -eq 'Desktop') -or [bool]$IsWindows

# Clipboard Helper
function clip {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)]
        [psobject]$InputObject
    )
    begin {
        $piped = [System.Collections.Generic.List[string]]::new()
    }
    process {
        if ($null -ne $InputObject) {
            $piped.Add([string]$InputObject)
        }
    }
    end {
        if ($piped.Count -gt 0) {
            Set-Clipboard -Value ($piped -join [Environment]::NewLine)
        } elseif ($args) {
            Set-Clipboard -Value ($args -join ' ')
        } else {
            Get-Clipboard
        }
    }
}

# Open Target (Explorer / Default App)
function open_target {
    param(
        [string]$Target = "."
    )
    if (Test-Path $Target) {
        Invoke-Item $Target
    } else {
        Start-Process $Target
    }
}

function _zen_timer_start {
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function _zen_timer_elapsed {
    param([System.Diagnostics.Stopwatch]$sw)
    $sw.Stop()
    $ms = $sw.ElapsedMilliseconds
    if ($ms -lt 1000) {
        return "${ms}ms"
    } elseif ($ms -lt 60000) {
        return "{0:N2}s" -f ($ms / 1000)
    } else {
        $m = [Math]::Floor($ms / 60000)
        $s = ($ms % 60000) / 1000
        return "{0}m {1:N1}s" -f $m, $s
    }
}

function _zen_sync {
    param([string[]]$Arguments = @())

    if ($Arguments -contains "-h" -or $Arguments -contains "--help") {
        Write-Host @"
Usage: zen sync [OPTIONS]

Pull latest commits from remote and reload dotfiles aliases and functions.

Options:
  -h, --help    Show this help message

Note: To reconfigure system modules or run full provisioning, use 'zen setup'.
"@
        return
    }

    $dotfilesRoot = if ($global:DOTFILES_DIR -and (Test-Path $global:DOTFILES_DIR)) {
        $global:DOTFILES_DIR
    } elseif (Test-Path "$env:USERPROFILE\.config\zencli") {
        "$env:USERPROFILE\.config\zencli"
    } elseif (Test-Path "$env:USERPROFILE\.config\zen") {
        "$env:USERPROFILE\.config\zen"
    } elseif (Test-Path "$env:USERPROFILE\.config\dotfiles") {
        "$env:USERPROFILE\.config\dotfiles"
    } else {
        $null
    }

    if (-not $dotfilesRoot) {
        Write-Error "Dotfiles repository directory not found."
        return
    }

    $sw = _zen_timer_start

    Write-Host "==> Syncing ZenCLI Ecosystem ($dotfilesRoot)..." -ForegroundColor Cyan

    # 1. Pull latest commits quietly
    if (Test-Path "$dotfilesRoot\.git") {
        if (Get-Command git.exe -ErrorAction SilentlyContinue) {
            $oldHead = (& git.exe -C $dotfilesRoot rev-parse --short HEAD 2>$null)
            $pullErr = (& git.exe -C $dotfilesRoot pull --rebase --autostash --quiet 2>&1)
            $pullSuccess = ($LASTEXITCODE -eq 0)
            $newHead = (& git.exe -C $dotfilesRoot rev-parse --short HEAD 2>$null)

            if (-not $pullSuccess) {
                Write-Host "  ✖ Git pull failed:" -ForegroundColor Red
                if ($pullErr) { Write-Host $pullErr -ForegroundColor Red }
            } elseif ($oldHead -ne $newHead) {
                Write-Host "  ✔ Pulled $newHead" -ForegroundColor Green
            } else {
                Write-Host "  ✔ Repository up to date ($newHead)" -ForegroundColor Green
            }
        } else {
            Write-Host "  ✖ git.exe not found on PATH; skipping git pull." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ℹ '$dotfilesRoot' is not a git repository; skipping git pull." -ForegroundColor DarkGray
    }

    # 2. Global Git Aliases
    if ((Get-Command git.exe -ErrorAction SilentlyContinue) -and (Test-Path "$dotfilesRoot\.gitconfig")) {
        $gitconfigPosix = "$dotfilesRoot\.gitconfig" -replace '\\', '/'
        $includes = @(& git.exe config --global --get-all include.path 2>$null)
        if ($includes -notcontains $gitconfigPosix -and $includes -notcontains "$dotfilesRoot\.gitconfig") {
            & git.exe config --global --add include.path $gitconfigPosix
        }
    }

    # 3. Reload PowerShell Core Components
    $coreScripts = Get-ChildItem -Path "$dotfilesRoot\powershell\core\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name
    $loadedCount = 0
    foreach ($script in $coreScripts) {
        try {
            . $script.FullName
            $loadedCount++
        } catch {
            Write-Warning "Failed loading $($script.Name): $_"
        }
    }

    # 4. Reload Local Machine Configurations if present
    $localPs1 = "$dotfilesRoot\local\local.ps1"
    if (Test-Path $localPs1) {
        . $localPs1
    }

    Write-Host "  ✔ Refreshed session ($loadedCount components)" -ForegroundColor Green
    $elapsed = _zen_timer_elapsed $sw
    Write-Host "✔ Done in $elapsed" -ForegroundColor Cyan
}

function _zen_alias_catalog {
    param(
        [Parameter(Position = 0)]
        [string]$Query = ""
    )

    if ($Query -in "list", "all") { $Query = "" }

    Write-Host @"

=== ZENCLI SHORTCUT & ALIAS DIRECTORY (Windows PowerShell) ===
Authoritative registry of navigation, system, and dev aliases
"@ -ForegroundColor Cyan

    $categories = [ordered]@{
        "ENVIRONMENT & RELOAD" = @(
            @{ Name = "rel"; Cmd = "Reload PowerShell profile (`$PROFILE)"; Desc = "Reload profile" }
            @{ Name = "gete [var]"; Cmd = "Inspect variable in Process/User/Machine"; Desc = "Inspect env vars" }
            @{ Name = "pathadd <dir>"; Cmd = "Add directory to PATH (Prepend/Append)"; Desc = "Safe PATH modification" }
            @{ Name = "set_editor [name]"; Cmd = "Set default EDITOR in User Registry & ~/.env"; Desc = "Set system editor" }
            @{ Name = "conf [key]"; Cmd = "Quick open config (env, git, ssh, profile...)"; Desc = "Config editor" }
            @{ Name = "e [file]"; Cmd = "Open target with default configured editor"; Desc = "Open in editor" }
            @{ Name = "ts"; Cmd = "[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()"; Desc = "Quick Unix timestamp" }
            @{ Name = "zen sync"; Cmd = "Pull latest commits & reload aliases"; Desc = "Sync repository" }
            @{ Name = "zen setup"; Cmd = "Modular dotfiles setup & installer"; Desc = "Dotfiles setup" }
            @{ Name = "ins / insdf"; Cmd = "zen / zen setup"; Desc = "Setup shorthand" }
            @{ Name = "zen ski [source]"; Cmd = "npx skills add/rm/ls/update"; Desc = "Agent skills orchestrator" }
            @{ Name = "zen skiv [opts]"; Cmd = "zen ski venhdev/skills"; Desc = "Personal skills (default: .agents/skills)" }
            @{ Name = "zen skiup"; Cmd = "zen ski update -p -y"; Desc = "Update project skills from lockfile" }
        )
        "PYTHON VENV" = @(
            @{ Name = "va"; Cmd = "Activate .venv, venv, or env"; Desc = "Activate Python venv" }
            @{ Name = "vd"; Cmd = "deactivate"; Desc = "Deactivate Python venv" }
        )
        "SECURITY & NETWORK CHECK" = @(
            @{ Name = "curlip"; Cmd = "(Invoke-RestMethod https://ifconfig.me).Trim()"; Desc = "Quick public IP check" }
            @{ Name = "killport <port>"; Cmd = "Stop-Process on port with Get-NetTCPConnection"; Desc = "Terminate process by port" }
        )
        "PROCESS & SYSTEM MONITORING" = @(
            @{ Name = "wslcompact"; Cmd = "Compact ext4.vhdx using Hyper-V / DiskPart"; Desc = "Reclaim WSL disk space" }
            @{ Name = "sleepin [min]"; Cmd = "Start-Sleep & SetSuspendState (default: 30m)"; Desc = "Countdown sleep timer" }
            @{ Name = "winsleep"; Cmd = "sleepin"; Desc = "Sleep alias" }
            @{ Name = "zen sleep [min]"; Cmd = "sleepin [min]"; Desc = "ZenCLI sleep gateway" }
        )
        "FILE & SYSTEM & NAVIGATION" = @(
            @{ Name = ".."; Cmd = "Set-Location .."; Desc = "Go up 1 directory" }
            @{ Name = "..."; Cmd = "Set-Location ../.."; Desc = "Go up 2 directories" }
            @{ Name = "ll"; Cmd = "Get-ChildItem -Path `$PWD"; Desc = "List files" }
            @{ Name = "la"; Cmd = "Get-ChildItem -Path `$PWD -Force"; Desc = "List all including hidden" }
            @{ Name = "mkcd <path>"; Cmd = "New-Item Directory & Set-Location"; Desc = "Create directory and enter" }
            @{ Name = "mktouch <path>"; Cmd = "Touch file creating parents if needed"; Desc = "Touch file" }
            @{ Name = "extract <file>"; Cmd = "Universal extractor (.zip, .tar, .gz...)"; Desc = "Extract archive" }
            @{ Name = "which <cmd>"; Cmd = "where.exe <cmd>"; Desc = "Find executable path" }
            @{ Name = "clip [text]"; Cmd = "Get-Clipboard / Set-Clipboard helper"; Desc = "Universal clipboard" }
        )
        "DIRECTORY DISK USAGE" = @(
            @{ Name = "dirsize [path]"; Cmd = "Multi-threaded robocopy disk usage breakdown"; Desc = "Folder disk sizes" }
            @{ Name = "dus [path]"; Cmd = "dirsize [path]"; Desc = "Shorthand for dirsize" }
        )
        "HISTORY SEARCH & COMMAND AUDIT" = @(
            @{ Name = "h [query] [n]"; Cmd = "Search PSReadLine persistent history"; Desc = "History search" }
            @{ Name = "clog [query]"; Cmd = "View recent confirmed commands audit log"; Desc = "Command audit log" }
            @{ Name = "cr [query|idx]"; Cmd = "Interactive picker or direct rerun from log"; Desc = "Rerun logged command" }
        )
    }

    $qLower = if ($Query) { $Query.ToLowerInvariant() } else { "" }

    foreach ($cat in $categories.Keys) {
        $items = $categories[$cat]
        $matched = @()
        foreach ($item in $items) {
            if (-not $qLower -or $item.Name.ToLowerInvariant().Contains($qLower) -or $item.Cmd.ToLowerInvariant().Contains($qLower) -or $item.Desc.ToLowerInvariant().Contains($qLower)) {
                $matched += $item
            }
        }

        if ($matched.Count -gt 0) {
            Write-Host "`n┌─[ $cat ]" -ForegroundColor DarkCyan
            foreach ($m in $matched) {
                $namePart = "  {0,-16}" -f $m.Name
                Write-Host $namePart -NoNewline -ForegroundColor Green
                Write-Host " → " -NoNewline -ForegroundColor DarkGray
                $cmdPart = "{0,-40}" -f $m.Cmd
                Write-Host $cmdPart -NoNewline -ForegroundColor White
                if ($m.Desc) {
                    Write-Host " # $($m.Desc)" -ForegroundColor DarkGray
                } else {
                    Write-Host ""
                }
            }
        }
    }

    # Also display Git Aliases if available
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $gitAliases = @(git.exe config --get-regexp '^alias\.' 2>$null)
        if ($gitAliases.Count -gt 0) {
            $gitMatched = @()
            foreach ($ga in $gitAliases) {
                if ($ga -match '^alias\.([^\s]+)\s+(.*)$') {
                    $aName = $Matches[1]
                    $aCmd = $Matches[2]
                    if (-not $qLower -or $aName.ToLowerInvariant().Contains($qLower) -or $aCmd.ToLowerInvariant().Contains($qLower)) {
                        $gitMatched += [PSCustomObject]@{ Name = "git $aName"; Cmd = $aCmd }
                    }
                }
            }

            if ($gitMatched.Count -gt 0) {
                Write-Host "`n┌─[ GIT CONFIGURATION SHORTCUTS ]" -ForegroundColor DarkCyan
                foreach ($gm in $gitMatched) {
                    $namePart = "  {0,-16}" -f $gm.Name
                    Write-Host $namePart -NoNewline -ForegroundColor Yellow
                    Write-Host " → " -NoNewline -ForegroundColor DarkGray
                    Write-Host "git $($gm.Cmd)" -ForegroundColor White
                }
            }
        }
    }
    Write-Host ""
}

function _zen_doctor {
    Write-Host "`n=== ZENCLI DOCTOR DIAGNOSTIC REPORT (Windows) ===" -ForegroundColor Cyan
    Write-Host "Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Edition: $PSEdition | Version: $($PSVersionTable.PSVersion)"

    # ZenCLI root
    $zenRoot = if ($global:ZENCLI_DIR -and (Test-Path $global:ZENCLI_DIR)) {
        $global:ZENCLI_DIR
    } elseif ($global:ZEN_DIR -and (Test-Path $global:ZEN_DIR)) {
        $global:ZEN_DIR
    } elseif ($global:DOTFILES_DIR -and (Test-Path $global:DOTFILES_DIR)) {
        $global:DOTFILES_DIR
    } elseif (Test-Path "$env:USERPROFILE\.config\zencli") {
        "$env:USERPROFILE\.config\zencli"
    } elseif (Test-Path "$env:USERPROFILE\.config\zen") {
        "$env:USERPROFILE\.config\zen"
    } else {
        "$env:USERPROFILE\.config\dotfiles"
    }

    if (Test-Path $zenRoot) {
        Write-Host "✔ ZenCLI root: $zenRoot" -ForegroundColor Green
    } else {
        Write-Host "✖ ZenCLI root missing: $zenRoot" -ForegroundColor Red
    }

    # Git
    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        $gitVer = (git.exe --version)
        Write-Host "✔ Git: $gitVer" -ForegroundColor Green
    } else {
        Write-Host "✖ Git not found on PATH" -ForegroundColor Yellow
    }

    # Package Manager
    $mgr = if (Get-Command winget.exe -ErrorAction SilentlyContinue) { "winget" }
           elseif (Get-Command scoop -ErrorAction SilentlyContinue) { "scoop" }
           elseif (Get-Command choco.exe -ErrorAction SilentlyContinue) { "choco" }
           else { $null }
    if ($mgr) {
        Write-Host "✔ Package Manager: $mgr" -ForegroundColor Green
    } else {
        Write-Host "✖ No supported package manager found (winget/scoop/choco)" -ForegroundColor Yellow
    }

    # Editor
    $ed = if ($env:EDITOR) { $env:EDITOR } else { "notepad.exe" }
    Write-Host "✔ Configured Editor: $ed" -ForegroundColor Green

    # Windows Terminal
    $wtSettings = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
    if (Test-Path $wtSettings) {
        Write-Host "✔ Windows Terminal settings detected" -ForegroundColor Green
    }

    # Profile
    if ($PROFILE -and (Test-Path $PROFILE)) {
        Write-Host "✔ PowerShell profile: $PROFILE" -ForegroundColor Green
    } else {
        Write-Host "✖ Profile not found at: $PROFILE" -ForegroundColor Yellow
    }
    Write-Host ""
}

function _zen_cmd_ski {
    param([string[]]$RemainingArgs)

    $npxCmd = if (Get-Command npx.cmd -ErrorAction SilentlyContinue) { "npx.cmd" }
              elseif (Get-Command npx -ErrorAction SilentlyContinue) { "npx" }
              else { $null }

    if (-not $npxCmd) {
        Write-Error "Error: 'npx' is required to manage agent skills. Run 'zen i nodejs' or install Node.js."
        return
    }

    if (-not $RemainingArgs -or $RemainingArgs.Count -eq 0) {
        Write-Host @"
zen ski - Agent Skills Orchestrator (powered by Vercel Skills CLI)

Usage:
  zen ski <source> [options]         Add skill(s) from GitHub, URL, or local path
  zen skiv [options]                 Personal skills (venhdev/skills, default: .agents/skills)
  zen skiup                          Update project skills according to lockfile (-p -y)

Common Management:
  zen ski update [skills...]         Update installed skills to latest versions
  zen ski rm <skill...>              Remove installed agent skill(s)
  zen ski ls [-g]                    List installed skills (project or global -g)
  zen ski find [query]               Search agent skills interactively
  zen ski check                      Check for available skill updates

Add Options:
  -g, --global                       Install to user directory (~/<agent>/skills)
  -a, --agent <agents...>            Target specific agent(s) (default for skiv: codex)
  -s, --skill <skills...>            Specify skill names to install
  -l, --list                         List available skills in source without installing
  -y, --yes                          Skip confirmation prompts
  --copy                             Copy files instead of symlinking

Examples:
  zen skiv                           Interactive selection into .agents/skills/
  zen skiv -y                        Install all personal skills to .agents/skills/
  zen skiv -s clarify                Install specific skill to .agents/skills/
  zen skiv -a claude-code            Install to Claude Code instead of default
  zen skiup                          Update all installed project skills
  zen ski vercel-labs/agent-skills   Install external skills
"@
        return
    }

    $sub = $RemainingArgs[0]
    $tail = if ($RemainingArgs.Count -gt 1) { $RemainingArgs[1..($RemainingArgs.Count - 1)] } else { @() }

    switch ($sub) {
        { $_ -in "-h", "--help", "help" } {
            _zen_cmd_ski
        }
        { $_ -in "rm", "remove" } {
            & $npxCmd --yes skills remove @tail
        }
        { $_ -in "ls", "list" } {
            & $npxCmd --yes skills list @tail
        }
        { $_ -in "update", "up", "upgrade" } {
            & $npxCmd --yes skills update @tail
        }
        "find" {
            & $npxCmd --yes skills find @tail
        }
        "check" {
            & $npxCmd --yes skills check @tail
        }
        "init" {
            & $npxCmd --yes skills init @tail
        }
        "add" {
            & $npxCmd --yes skills add @tail
        }
        { $_ -in "v", "venh" } {
            _zen_cmd_skiv -RemainingArgs $tail
        }
        default {
            & $npxCmd --yes skills add @RemainingArgs
        }
    }
}

function _zen_cmd_skiv {
    param([string[]]$RemainingArgs)

    $hasAgent = $false
    if ($RemainingArgs) {
        foreach ($arg in $RemainingArgs) {
            if ($arg -eq "-a" -or $arg -eq "--agent" -or $arg.StartsWith("--agent=")) {
                $hasAgent = $true
                break
            }
        }
    }
    if (-not $hasAgent) {
        _zen_cmd_ski -RemainingArgs (@("venhdev/skills", "-a", "codex") + $RemainingArgs)
    } else {
        _zen_cmd_ski -RemainingArgs (@("venhdev/skills") + $RemainingArgs)
    }
}

function _zen_version_ps {
    $root = if ($env:DOTFILES) { $env:DOTFILES } else { (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) }
    $commitSha = "-"
    $commitDate = "-"
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $cSha = git -C $root rev-parse --short HEAD 2>$null
        if ($cSha) { $commitSha = $cSha }
        $cDate = git -C $root log -1 --format="%cd" --date=short 2>$null
        if ($cDate) { $commitDate = $cDate }
    }
    $osDesc = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    $tz = [System.TimeZoneInfo]::Local
    $offset = $tz.GetUtcOffset([DateTime]::UtcNow)
    $sign = if ($offset.Hours -ge 0) { "+" } else { "-" }
    $offsetStr = "{0}{1:D2}:{2:D2}" -f $sign, [Math]::Abs($offset.Hours), [Math]::Abs($offset.Minutes)

    Write-Host "ZenCLI v1.2.0"
    Write-Host "Commit     : $commitSha ($commitDate)"
    Write-Host "Root       : $root"
    Write-Host "Platform   : $osDesc [Windows]"
    Write-Host "Timezone   : $($tz.Id) ($($tz.StandardName), UTC$offsetStr)"
}

function _zen_cmd_migrate_ps {
    param([string[]]$RemainingArgs)
    Write-Host "==> Checking ZenCLI migrations (Windows)..." -ForegroundColor Cyan
    $legacyState = "$env:LOCALAPPDATA\dotfiles"
    $targetState = if ($env:ZEN_STATE_DIR) { $env:ZEN_STATE_DIR } else { "$env:LOCALAPPDATA\zen" }
    $migrated = $false

    if (Test-Path $legacyState) {
        if (!(Test-Path $targetState)) {
            New-Item -ItemType Directory -Path $targetState -Force | Out-Null
        }
        if (Test-Path "$legacyState\commands.log") {
            if (!(Test-Path "$targetState\commands.log")) {
                Move-Item -Path "$legacyState\commands.log" -Destination "$targetState\commands.log" -Force
                Write-Host "  ✔ Migrated commands.log to $targetState\commands.log" -ForegroundColor Green
            } else {
                Get-Content "$legacyState\commands.log" | Add-Content "$targetState\commands.log"
                Remove-Item -Path "$legacyState\commands.log" -Force
                Write-Host "  ✔ Merged legacy commands.log into $targetState\commands.log" -ForegroundColor Green
            }
        }
        Remove-Item -Path $legacyState -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  ✔ Cleaned up legacy directory: $legacyState" -ForegroundColor Green
        $migrated = $true
    }

    if (-not $migrated) {
        Write-Host "✔ Windows environment is clean and up to date." -ForegroundColor Green
    }
}

# Universal Package Manager & Ecosystem shim
function zencli {
    param(
        [Parameter(Position = 0)]
        [string]$Action = "",
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$RemainingArgs
    )

    switch ($Action) {
        { $_ -in "-v", "--version", "version", "ver" } {
            _zen_version_ps
            return
        }
        "" {
            _zen_version_ps
            Write-Host ""
            # Fall through to default help display
        }
        "migrate" {
            _zen_cmd_migrate_ps -RemainingArgs $RemainingArgs
            return
        }
        "ski" {
            _zen_cmd_ski -RemainingArgs $RemainingArgs
            return
        }
        "skiv" {
            _zen_cmd_skiv -RemainingArgs $RemainingArgs
            return
        }
        "skiup" {
            _zen_cmd_ski -RemainingArgs (@("update", "-p", "-y") + $RemainingArgs)
            return
        }
        "sync" {
            _zen_sync -Arguments $RemainingArgs
            return
        }
        { $_ -in "ali", "alias" } {
            $q = if ($RemainingArgs.Count -gt 0) { $RemainingArgs -join " " } else { "" }
            _zen_alias_catalog -Query $q
            return
        }
        "doctor" {
            _zen_doctor
            return
        }
        "sleep" {
            if (Get-Command sleepin -ErrorAction SilentlyContinue) {
                sleepin @RemainingArgs
            } else {
                Write-Error "sleepin command not available."
            }
            return
        }
        { $_ -in "setup", "init" } {
            if (Get-Command insdf -ErrorAction SilentlyContinue) {
                insdf @RemainingArgs
            } else {
                Write-Error "ZenCLI setup command not available."
            }
            return
        }
    }

    # Package Management commands require a Windows package manager
    $mgr = if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        "winget"
    } elseif (Get-Command scoop -ErrorAction SilentlyContinue) {
        "scoop"
    } elseif (Get-Command choco.exe -ErrorAction SilentlyContinue) {
        "choco"
    } else {
        $null
    }

    switch ($Action) {
        { $_ -in "update", "up" } {
            if (-not $mgr) { Write-Error "No supported package manager found (winget, scoop, choco)."; return }
            switch ($mgr) {
                "winget" { winget.exe source update }
                "scoop"  { scoop update }
                "choco"  { choco.exe upgrade all -y --noop }
            }
        }
        "upgrade" {
            if (-not $mgr) { Write-Error "No supported package manager found (winget, scoop, choco)."; return }
            if ($RemainingArgs.Count -eq 0) {
                Write-Warning "Notice: 'zencli upgrade' requires an explicit target to prevent unintended system-wide changes."
                Write-Host @"
Usage:
  zencli upgrade --all       Upgrade system packages AND managed tools
  zencli upgrade system      Upgrade system package manager only
  zencli upgrade <package>   Upgrade or reinstall specific package
"@
                return
            }
            switch ($mgr) {
                "winget" { winget.exe upgrade --all }
                "scoop"  { scoop update * }
                "choco"  { choco.exe upgrade all -y }
            }
        }
        { $_ -in "install", "add", "i" } {
            if (-not $mgr) { Write-Error "No supported package manager found (winget, scoop, choco)."; return }
            if ($RemainingArgs.Count -eq 0) {
                Write-Error "Error: Missing package name. Usage: zencli i <package...>"
                return
            }
            switch ($mgr) {
                "winget" { winget.exe install @RemainingArgs }
                "scoop"  { scoop install @RemainingArgs }
                "choco"  { choco.exe install @RemainingArgs -y }
            }
        }
        { $_ -in "remove", "uninstall", "rm" } {
            if (-not $mgr) { Write-Error "No supported package manager found (winget, scoop, choco)."; return }
            if ($RemainingArgs.Count -eq 0) {
                Write-Error "Error: Missing package name to remove. Usage: zencli rm <package...>"
                return
            }
            switch ($mgr) {
                "winget" { winget.exe uninstall @RemainingArgs }
                "scoop"  { scoop uninstall @RemainingArgs }
                "choco"  { choco.exe uninstall @RemainingArgs -y }
            }
        }
        "search" {
            if (-not $mgr) { Write-Error "No supported package manager found (winget, scoop, choco)."; return }
            if ($RemainingArgs.Count -eq 0) {
                Write-Error "Error: Missing search query. Usage: zencli search <query>"
                return
            }
            switch ($mgr) {
                "winget" { winget.exe search @RemainingArgs }
                "scoop"  { scoop search @RemainingArgs }
                "choco"  { choco.exe search @RemainingArgs }
            }
        }
        default {
            $mgrDisplay = if ($mgr) { $mgr } else { "none detected (install winget or scoop)" }
            Write-Host @"
ZenCLI - Unified Ecosystem Gateway & Developer Tool Orchestrator

Usage:
  zencli <command> [arguments...]
  zen    <command> [arguments...] (terminal shorthand)

Core & Help:
  zencli                   Show version summary and quick command helper
  zencli -v, --version     Show version and environment details
  zencli -h, --help        Show this help message
  zencli migrate           Audit and migrate legacy configurations/state

Headless Package Management:
  zencli i <package...>    Install a package (shorthand for zencli install)
  zencli rm <package...>   Uninstall a package (shorthand for zencli remove)
  zencli update            Refresh package indexes
  zencli upgrade --all     Upgrade all installed packages
  zencli search <query>    Search for packages

Agent Skills Management:
  zencli ski [source|cmd]  Agent skills orchestrator (add, rm, ls, update, find)
  zencli skiv [options]    Personal skills (venhdev/skills, default: .agents/skills)
  zencli skiup             Update project skills according to lockfile (-p -y)

Ecosystem & Workstation:
  zencli sync              Pull latest commits & reload aliases into session
  zencli setup [mods...]   Run ZenCLI installer & module setup
  zencli sleep [minutes]   Put computer to sleep after countdown (default: 30)
  zencli ali [query]       Search & list shortcuts and aliases
  zencli doctor            Diagnose environment health & tool paths

Active manager detected: $mgrDisplay
"@
        }
    }
}

# Terminal shorthand alias for zencli
function zen {
    zencli @args
}
