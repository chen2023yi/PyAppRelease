<#
.SYNOPSIS
    Install PyAppRelease module to the current user's PowerShell module path.

.DESCRIPTION
    Copies PyAppRelease.psm1 and PyAppRelease.psd1 to the first user-writable
    directory in $env:PSModulePath. After installation the module is available
    in any PowerShell session via:

        Import-Module PyAppRelease
        Invoke-PyAppRelease -DryRun

.PARAMETER Force
    Overwrite an existing installation without prompting.

.EXAMPLE
    .\Install.ps1
    .\Install.ps1 -Force
#>
param([switch]$Force)

$moduleName = "PyAppRelease"
$srcDir     = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Find a writable user-level module directory ──────────────────────────────
$userModPath = ($env:PSModulePath -split ';') |
    Where-Object {
        ($_ -like "*$env:USERPROFILE*" -or $_ -like "*Documents*") -and
        $_ -notlike "*system32*"
    } |
    Select-Object -First 1

if (-not $userModPath) {
    # Fallback: standard Windows PowerShell 5.x user path
    $userModPath = "$HOME\Documents\WindowsPowerShell\Modules"
}

$destDir = Join-Path $userModPath $moduleName

# ── Guard existing install ────────────────────────────────────────────────────
if ((Test-Path $destDir) -and -not $Force) {
    $existing = ""
    $mf = Join-Path $destDir "$moduleName.psd1"
    if (Test-Path $mf) {
        $existing = (Import-PowerShellDataFile $mf).ModuleVersion
    }
    $answer = Read-Host "PyAppRelease $existing already installed at:`n  $destDir`nOverwrite? [y/N]"
    if ($answer -notmatch '^[yY]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# ── Copy files ────────────────────────────────────────────────────────────────
if (-not (Test-Path $destDir)) {
    New-Item -ItemType Directory -Path $destDir | Out-Null
}

Copy-Item "$srcDir\$moduleName.psm1"     -Destination $destDir -Force
Copy-Item "$srcDir\$moduleName.psd1"     -Destination $destDir -Force
Copy-Item "$srcDir\$moduleName-GUI.ps1"  -Destination $destDir -Force

# ── Verify ────────────────────────────────────────────────────────────────────
$ver = (Import-PowerShellDataFile (Join-Path $destDir "$moduleName.psd1")).ModuleVersion

Write-Host ""
Write-Host "PyAppRelease v$ver installed to:" -ForegroundColor Green
Write-Host "  $destDir"
Write-Host ""
Write-Host "Usage:" -ForegroundColor Cyan
Write-Host "  Import-Module PyAppRelease"
Write-Host "  Start-PyAppReleaseGUI                         # graphical tool (GUI)"
Write-Host "  Invoke-PyAppRelease -DryRun                   # command-line preview"
Write-Host "  Invoke-PyAppRelease                           # patch bump + build + tag"
Write-Host "  Invoke-PyAppRelease -BumpMinor -SkipSign      # minor bump, no signing"
Write-Host "  New-PyAppReleaseConfig -AppName MyApp         # scaffold config for a new project"
Write-Host ""
