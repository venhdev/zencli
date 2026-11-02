# Quick configuration opener for Windows PowerShell (conf)

function Get-ConfigEditor {
    if ($env:EDITOR) {
        $env:EDITOR
    } elseif ($env:DOTFILES_EDITOR) {
        $env:DOTFILES_EDITOR
    } elseif (Get-Command code -ErrorAction SilentlyContinue) {
        "code"
    } else {
        "notepad.exe"
    }
}

function e {
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Path
    )
    $editor = Get-ConfigEditor
    if ($Path) {
        & $editor @Path
    } else {
        & $editor
    }
}

function set_editor {
    param(
        [Parameter(Position = 0)]
        [string]$Name = ""
    )

    $commonEditors = @("notepad", "code", "nvim", "vim", "micro", "nano", "cursor", "subl")

    # If no argument passed, scan installed editors and prompt interactive menu
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $detected = @()
        foreach ($ed in $commonEditors) {
            if (Get-Command $ed -ErrorAction SilentlyContinue) {
                $detected += $ed
            }
        }
        if ($detected.Count -eq 0) { $detected = @("notepad") }

        Write-Host "=== Select Default Editor ===" -ForegroundColor Cyan
        for ($i = 0; $i -lt $detected.Count; $i++) {
            $currentTag = if ($env:EDITOR -eq $detected[$i]) { " [current]" } else { "" }
            Write-Host ("  {0}) {1}{2}" -f ($i + 1), $detected[$i], $currentTag)
        }
        $pick = Read-Host "`nEnter number (1-$($detected.Count)) or custom command"
        if ([string]::IsNullOrWhiteSpace($pick)) { return }

        if ($pick -match '^[0-9]+$' -and [int]$pick -ge 1 -and [int]$pick -le $detected.Count) {
            $Name = $detected[[int]$pick - 1]
        } else {
            $Name = $pick.Trim()
        }
    }

    # Verify command availability
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Warning "Command '$Name' was not found on PATH. Setting anyway..."
    }

    # 1. Update current session
    $env:EDITOR = $Name
    $env:VISUAL = $Name

    # 2. Persist to Windows User Environment
    [Environment]::SetEnvironmentVariable("EDITOR", $Name, "User")
    [Environment]::SetEnvironmentVariable("VISUAL", $Name, "User")

    # 3. Persist to ~/.env if present or update key
    $userEnv = "$env:USERPROFILE\.env"
    if (Test-Path $userEnv) {
        $lines = Get-Content $userEnv -ErrorAction SilentlyContinue
        $found = $false
        $newLines = @()
        foreach ($l in $lines) {
            if ($l -match '^\s*EDITOR\s*=') {
                $newLines += "EDITOR=$Name"
                $found = $true
            } else {
                $newLines += $l
            }
        }
        if (-not $found) {
            $newLines += "EDITOR=$Name"
        }
        Set-Content -Path $userEnv -Value $newLines -Encoding utf8
    }

    Write-Host "✓ Default EDITOR set and persisted to '$Name'" -ForegroundColor Green
}

function conf {
    param(
        [Parameter(Position = 0)]
        [string]$Key = ""
    )

    $dotfiles = if ($global:DOTFILES_DIR) {
        $global:DOTFILES_DIR
    } elseif (Test-Path "$env:USERPROFILE\.config\zencli") {
        "$env:USERPROFILE\.config\zencli"
    } elseif (Test-Path "$env:USERPROFILE\.config\zen") {
        "$env:USERPROFILE\.config\zen"
    } else {
        "$env:USERPROFILE\.config\dotfiles"
    }

    $configMap = [ordered]@{
        "profile"    = $PROFILE
        "prof"       = $PROFILE
        "pwprofile"  = "$dotfiles\powershell\profile.ps1"
        "env"        = "$env:USERPROFILE\.env"
        "localenv"   = "$dotfiles\local\local.ps1"
        "sysenv"     = "[Windows Environment Variables Dialog]"
        "git"        = "$env:USERPROFILE\.gitconfig"
        "gitdot"     = "$dotfiles\.gitconfig"
        "ssh"        = "$env:USERPROFILE\.ssh\config"
        "claude"     = "$env:USERPROFILE\.claude\settings.json"
        "cmdlog"     = "$dotfiles\powershell\core\15-CmdLog.ps1"
        "ali"        = "$dotfiles\powershell\core\10-BaseAliases.ps1"
        "shims"      = "$dotfiles\powershell\core\00-PlatformShims.ps1"
        "wsl"        = "$dotfiles\powershell\core\20-WslHost.ps1"
        "starship"   = "$env:USERPROFILE\.config\starship.toml"
    }

    # Discover additional .ps1 scripts in powershell/
    $extraScripts = Get-ChildItem -Path "$dotfiles\powershell\core\*.ps1" -ErrorAction SilentlyContinue
    foreach ($s in $extraScripts) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($s.Name)
        if (-not $configMap.Contains($base)) {
            $configMap[$base] = $s.FullName
        }
    }

    if ([string]::IsNullOrWhiteSpace($Key)) {
        Write-Host "=== Available Configurations ===" -ForegroundColor Cyan
        foreach ($k in $configMap.Keys) {
            Write-Host ("  {0,-12} {1}" -f $k, $configMap[$k])
        }
        $Key = Read-Host "`nEnter key to open"
        if ([string]::IsNullOrWhiteSpace($Key)) { return }
    }

    $Key = $Key.Trim()
    if ($Key -match '^conf\s+(.+)$') {
        $Key = $Matches[1].Trim()
    }

    if ($Key -eq "sysenv") {
        Write-Host "Opening Windows Environment Variables dialog..." -ForegroundColor Green
        Start-Process "rundll32.exe" -ArgumentList "sysdm.cpl,EditEnvironmentVariables"
        return
    }

    $foundKey = $configMap.Keys | Where-Object { $_ -eq $Key } | Select-Object -First 1
    if ($foundKey) {
        $target = $configMap[$foundKey]

        # Auto-create target if file does not exist yet
        $parentDir = Split-Path -Parent $target
        if ($parentDir -and -not (Test-Path $parentDir)) {
            New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
        }
        if (-not (Test-Path $target)) {
            New-Item -ItemType File -Path $target -Force | Out-Null
        }

        $editor = Get-ConfigEditor
        Write-Host "Opening $target with $editor..." -ForegroundColor Green
        & $editor $target
    } else {
        Write-Warning "Configuration '$Key' not found in registry."
    }
}
