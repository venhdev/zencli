# Dotfiles PowerShell Root Profile
# Sourced by $PROFILE (Microsoft.PowerShell_profile.ps1)

# Ensure UTF-8 Console Encoding for clean Unicode output
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

$global:DOTFILES_DIR = if ($env:ZENCLI_DIR) {
    $env:ZENCLI_DIR
} elseif ($env:ZEN_DIR) {
    $env:ZEN_DIR
} elseif ($env:DOTFILES) {
    $env:DOTFILES
} elseif (Test-Path "$env:USERPROFILE\.config\zencli") {
    "$env:USERPROFILE\.config\zencli"
} elseif (Test-Path "$env:USERPROFILE\.config\zen") {
    "$env:USERPROFILE\.config\zen"
} elseif (Test-Path "$env:USERPROFILE\.config\dotfiles") {
    "$env:USERPROFILE\.config\dotfiles"
} else {
    Split-Path -Parent $PSScriptRoot
}

# 1. Standardize User Binary Directories in PATH (~/bin, ~/.local/bin)
$customBinDirs = @(
    "$env:USERPROFILE\bin",
    "$env:USERPROFILE\.local\bin"
)
foreach ($binDir in $customBinDirs) {
    if (Test-Path $binDir) {
        $cleanDir = $binDir.TrimEnd('\', '/')
        $currentPaths = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.TrimEnd('\', '/') -ne $cleanDir })
        $env:PATH = (@($cleanDir) + $currentPaths) -join ';'
    }
}

# 2. Load ~/.env environment file if present (key=value pairs)
$userEnv = "$env:USERPROFILE\.env"
if (Test-Path $userEnv) {
    Get-Content $userEnv -ErrorAction SilentlyContinue | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#") -and ($line -match '^\s*([^=]+)=(.*)$')) {
            $k = $Matches[1].Trim()
            $v = $Matches[2].Trim().Trim('"', "'")
            [System.Environment]::SetEnvironmentVariable($k, $v, 'Process')
        }
    }
}

# 3. Load Core PowerShell Components
$coreScripts = Get-ChildItem -Path "$global:DOTFILES_DIR\powershell\core\*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($script in $coreScripts) {
    . $script.FullName
}

# 4. Load Local Machine Configurations if present
$localPs1 = "$global:DOTFILES_DIR\local\local.ps1"
if (Test-Path $localPs1) {
    . $localPs1
}

# 3. Reload helper
function rel {
    if ($PROFILE -and (Test-Path $PROFILE)) {
        . $PROFILE
        Write-Host "✓ Reloaded $PROFILE" -ForegroundColor Green
    } else {
        . "$global:DOTFILES_DIR\powershell\profile.ps1"
        Write-Host "✓ Reloaded Dotfiles PowerShell profile" -ForegroundColor Green
    }
}
