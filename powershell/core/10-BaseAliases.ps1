# Base navigation, python virtualenv, and convenience shortcuts for PowerShell

# Navigation Shortcuts
function .. { Set-Location .. }
function ... { Set-Location ../.. }

# Safe Environment PATH Modification (Cross-Platform)
function Add-Path {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Path,
        [Parameter(Position = 1)]
        [ValidateSet("Prepend", "Append")]
        [string]$Position = "Prepend"
    )
    $cleanPath = $Path.TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $cleanPath)) { return }

    $paths = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\', '/') -ne $cleanPath })
    if ($Position -eq "Append") {
        $env:PATH = ($paths + $cleanPath) -join ';'
    } else {
        $env:PATH = (@($cleanPath) + $paths) -join ';'
    }
}
Set-Alias -Name pathadd -Value Add-Path -ErrorAction SilentlyContinue

# Deep Navigation & Directory Creation
function mkcd {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Path
    )
    $target = $Path[-1]
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Set-Location -LiteralPath $target
}

# Ensure Parent Directories and Touch Files
function mktouch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Paths
    )
    foreach ($p in $Paths) {
        $parent = Split-Path -Parent $p
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType File -Path $p -Force | Out-Null
        } else {
            (Get-Item -LiteralPath $p).LastWriteTime = [DateTime]::UtcNow
        }
    }
}

# Universal Archive Extractor
function extract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Files
    )
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f)) {
            Write-Warning "extract: '$f' does not exist."
            continue
        }
        $ext = [System.IO.Path]::GetExtension($f).ToLowerInvariant()
        $fullPath = (Resolve-Path -LiteralPath $f).Path
        $destDir = Split-Path -Parent $fullPath
        switch ($ext) {
            ".zip" {
                Expand-Archive -LiteralPath $fullPath -DestinationPath $destDir -Force
            }
            { $_ -in ".gz", ".tgz", ".bz2", ".tbz2", ".xz", ".txz", ".tar" } {
                if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
                    tar.exe -xf $fullPath -C $destDir
                } else {
                    Write-Warning "extract: tar.exe required for $ext archive extraction."
                }
            }
            default {
                Write-Warning "extract: unsupported archive extension '$ext'."
            }
        }
    }
}

# File Listing
function ll { Get-ChildItem -Path (Get-Item -Path $PWD) }
function la { Get-ChildItem -Path (Get-Item -Path $PWD) -Force }

# Executable Path Lookup (equivalent to POSIX 'which')
Set-Alias -Name which -Value where.exe -ErrorAction SilentlyContinue

# History Search (PSReadLine persistent history, default limit: 10)
function h {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Arg1 = "",
        [Parameter(Position = 1)]
        [string]$Arg2 = "",
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$RemainingArgs
    )

    $query = ""
    $limit = 10

    $allArgs = @()
    if ($Arg1) { $allArgs += $Arg1 }
    if ($Arg2) { $allArgs += $Arg2 }
    if ($RemainingArgs) { $allArgs += $RemainingArgs }

    switch ($allArgs.Count) {
        0 {
            $query = ""
            $limit = 10
        }
        1 {
            if ($allArgs[0] -match '^[0-9]+$') {
                $limit = [int]$allArgs[0]
                $query = ""
            } else {
                $query = $allArgs[0]
                $limit = 10
            }
        }
        default {
            $last = $allArgs[-1]
            if ($last -match '^[0-9]+$') {
                $limit = [int]$last
                $query = ($allArgs[0..($allArgs.Count - 2)] -join " ")
            } elseif ($allArgs[0] -match '^[0-9]+$') {
                $limit = [int]$allArgs[0]
                $query = ($allArgs[1..($allArgs.Count - 1)] -join " ")
            } else {
                $query = ($allArgs -join " ")
                $limit = 10
            }
        }
    }

    if ($limit -le 0) { $limit = 10 }

    $histPath = $null
    if (Get-Command Get-PSReadLineOption -ErrorAction SilentlyContinue) {
        $histPath = (Get-PSReadLineOption).HistorySavePath
    }
    if (-not $histPath -or -not (Test-Path $histPath)) {
        $candidates = @(
            "$env:APPDATA\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt",
            "$env:APPDATA\Microsoft\PowerShell\PSReadLine\ConsoleHost_history.txt",
            "$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) { $histPath = $c; break }
        }
    }

    $results = @()
    if ($histPath -and (Test-Path $histPath)) {
        $lines = Get-Content -Path $histPath -ErrorAction SilentlyContinue
        if (-not $lines) { return }

        $lines = @($lines | Where-Object { $_ -notmatch '^\s*h(\s+|$)' })

        if ($query) {
            $filtered = $lines | Where-Object { $_ -like "*$query*" }
            $results = @($filtered | Select-Object -Unique | Select-Object -Last $limit)
        } else {
            $results = @($lines | Select-Object -Last $limit)
        }
    } else {
        if ($query) {
            $results = @(Get-History | Where-Object { $_.CommandLine -like "*$query*" } | Select-Object -Last $limit | ForEach-Object { $_.CommandLine })
        } else {
            $results = @(Get-History -Count $limit | ForEach-Object { $_.CommandLine })
        }
    }

    for ($i = 0; $i -lt $results.Count; $i++) {
        Write-Host (" {0,2}) " -f ($i + 1)) -NoNewline -ForegroundColor DarkGray
        Write-Host $results[$i]
    }
}

# Inspect Environment Variables (run 'gete' to list all, or 'gete <Name>' to query specific variable)
function gete {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        Get-ChildItem Env: | Sort-Object Name | Select-Object Name, Value
        return
    }

    $procVal = [Environment]::GetEnvironmentVariable($Name, 'Process')
    $userVal = [Environment]::GetEnvironmentVariable($Name, 'User')
    $machVal = [Environment]::GetEnvironmentVariable($Name, 'Machine')

    if ($null -eq $procVal -and $null -eq $userVal -and $null -eq $machVal) {
        Write-Warning "Environment variable '$Name' not found."
        return
    }

    @(
        [pscustomobject]@{
            Name  = $Name
            Scope = 'Process'
            Value = $procVal
        }
        [pscustomobject]@{
            Name  = $Name
            Scope = 'User'
            Value = $userVal
        }
        [pscustomobject]@{
            Name  = $Name
            Scope = 'Machine'
            Value = $machVal
        }
    )
}

# Python Virtual Environment activation
function va {
    $venvPaths = @(
        ".venv\Scripts\Activate.ps1",
        "venv\Scripts\Activate.ps1",
        "env\Scripts\Activate.ps1"
    )
    foreach ($p in $venvPaths) {
        if (Test-Path $p) {
            . $p
            Write-Host "✓ Activated $p" -ForegroundColor Green
            return
        }
    }
    Write-Warning "No virtualenv found at .venv, venv, or env"
}

function vd {
    if (Get-Command deactivate -ErrorAction SilentlyContinue) {
        deactivate
        Write-Host "✓ Virtual environment deactivated" -ForegroundColor Green
    } else {
        Write-Warning "No active virtual environment detected."
    }
}

# Quick Timestamp
function ts { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }

# Public IP Check
function curlip { (Invoke-RestMethod -Uri "https://ifconfig.me" -TimeoutSec 5).Trim() }

# Graceful Port Termination (Cross-Platform)
function killport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [int]$Port,
        [Parameter(Position = 1)]
        [switch]$Force
    )
    $connections = @(Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue)
    if ($connections.Count -eq 0) {
        Write-Host "No listening process found on port $Port."
        return
    }
    $pids = $connections | Select-Object -ExpandProperty OwningProcess -Unique | Where-Object { $_ -gt 0 }
    if ($pids.Count -eq 0) {
        Write-Host "No process ID associated with port $Port."
        return
    }
    Write-Host "Terminating process(es) on port ${Port}: $($pids -join ', ')..."
    foreach ($pidToKill in $pids) {
        try {
            Stop-Process -Id $pidToKill -Force:$Force -ErrorAction Stop
        } catch {
            Write-Warning "Failed to stop PID $pidToKill : $_"
        }
    }
    Write-Host "✓ Port $Port released." -ForegroundColor Green
}

# Dotfiles Installer & Module Helpers (Cross-Platform parity with POSIX)
function insdf {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$Modules
    )

    $installerPs1 = "$global:DOTFILES_DIR\install.ps1"
    if (-not (Test-Path $installerPs1)) {
        $installerPs1 = "$env:USERPROFILE\.config\zencli\install.ps1"
    }
    if (-not (Test-Path $installerPs1)) {
        $installerPs1 = "$env:USERPROFILE\.config\zen\install.ps1"
    }
    if (-not (Test-Path $installerPs1)) {
        $installerPs1 = "$env:USERPROFILE\.config\dotfiles\install.ps1"
    }

    if ($Modules.Count -eq 0 -and (Test-Path $installerPs1)) {
        & $installerPs1
    } elseif (Get-Command bash.exe -ErrorAction SilentlyContinue) {
        $installerSh = "$global:DOTFILES_DIR/install.sh" -replace '\\', '/'
        bash.exe $installerSh @Modules
    } elseif (Test-Path $installerPs1) {
        & $installerPs1
    } else {
        Write-Error "Dotfiles installer not found at $global:DOTFILES_DIR"
    }
}
Set-Alias -Name ins -Value "zen" -ErrorAction SilentlyContinue
