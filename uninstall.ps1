# Dotfiles Windows PowerShell Uninstaller
# Usage:
#   .\uninstall.ps1

[CmdletBinding()]
param(
    [string]$TargetDir = "$env:USERPROFILE\.config\zencli",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $Force) {
    $confirm = Read-Host "Uninstall dotfiles from Windows? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "Cancelled."
        return
    }
}

Write-Host "Uninstalling dotfiles..." -ForegroundColor Yellow

$manifestFile = "$TargetDir\.installed.json"
if (Test-Path $manifestFile) {
    try {
        $manifest = Get-Content -Path $manifestFile -Raw | ConvertFrom-Json
        
        # 1. Restore terminal configs
        if ($manifest.terminal_configs) {
            foreach ($term in $manifest.terminal_configs) {
                if ($term.backup -and (Test-Path $term.backup)) {
                    Copy-Item -Path $term.backup -Destination $term.path -Force
                    Remove-Item -Path $term.backup -Force -ErrorAction SilentlyContinue
                    Write-Host "✔ Restored $($term.name) settings from backup: $($term.path)" -ForegroundColor Green
                }
            }
        }

        # 2. Remove symlinks & restore backups
        if ($manifest.symlinks) {
            foreach ($sym in $manifest.symlinks) {
                if (Test-Path $sym.link) {
                    Remove-Item -Path $sym.link -Force -ErrorAction SilentlyContinue
                    Write-Host "✔ Removed symlink: $($sym.link)" -ForegroundColor Green
                }
                if ($sym.backup -and (Test-Path $sym.backup)) {
                    Move-Item -Path $sym.backup -Destination $sym.link -Force
                    Write-Host "✔ Restored backup: $($sym.link)" -ForegroundColor Green
                }
            }
        }

        # 3. Clean shell hooks
        if ($manifest.shell_hooks) {
            foreach ($hook in $manifest.shell_hooks) {
                if (Test-Path $hook) {
                    $content = Get-Content -Path $hook -Raw -ErrorAction SilentlyContinue
                    if ($content -and $content -like "*# Load dotfiles*") {
                        $pattern = "(?s)\r?\n?# Load dotfiles.*?# End dotfiles\r?\n?"
                        $cleaned = [regex]::Replace($content, $pattern, "")
                        Set-Content -Path $hook -Value $cleaned.TrimEnd() -Encoding utf8
                        Write-Host "✔ Cleaned dotfiles hook from: $hook" -ForegroundColor Green
                    }
                }
            }
        }

        # 4. Unset git includes
        if ($manifest.git_includes) {
            foreach ($inc in $manifest.git_includes) {
                if (Get-Command git -ErrorAction SilentlyContinue) {
                    git config --global --unset-all include.path $inc 2>$null
                    Write-Host "✔ Unset git include.path: $inc" -ForegroundColor Green
                }
            }
        }
    } catch {
        Write-Warning "Failed to parse manifest: $_"
    }
}

# Fallback clean for $PROFILE if not cleaned via manifest
if ($PROFILE -and (Test-Path $PROFILE)) {
    $content = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($content -and $content -like "*# Load dotfiles*") {
        $pattern = "(?s)\r?\n?# Load dotfiles.*?# End dotfiles\r?\n?"
        $cleaned = [regex]::Replace($content, $pattern, "")
        Set-Content -Path $PROFILE -Value $cleaned.TrimEnd() -Encoding utf8
    }
}

$gitConfigPath = "$TargetDir\.gitconfig"
if (Get-Command git -ErrorAction SilentlyContinue) {
    git config --global --unset-all include.path $gitConfigPath 2>$null
}

# Remove manifest
Remove-Item -Path $manifestFile -Force -ErrorAction SilentlyContinue

Write-Host @"
============================================================
✔ Dotfiles successfully uninstalled from Windows!
============================================================
"@ -ForegroundColor Green
