#Requires -Version 5.1
<#
.SYNOPSIS
    PyAppRelease — reusable Python / PyInstaller / Inno Setup release pipeline module.

.DESCRIPTION
    Provides two public commands:

      Invoke-PyAppRelease    Run the full release pipeline for any Python desktop app.
      New-PyAppReleaseConfig Scaffold a release.config.psd1 for a new project.

    The pipeline steps are:
      1. Semantic version bump (major / minor / patch) written to a VERSION file
      2. PyInstaller build with embedded Windows version-info metadata
      3. Optional code signing of the generated EXE
      4. Inno Setup installer build (ISCC)
      5. Optional code signing of the installer
      6. SHA-256 checksum file
      7. git commit + tag + push

    Certificate configuration (set before running):
      PFX file   : $env:PYAPP_SIGN_PFX + $env:PYAPP_SIGN_PASSWORD
      Store thumb: $env:PYAPP_SIGN_THUMBPRINT
      Timestamp  : $env:PYAPP_SIGN_TIMESTAMP  (default: http://timestamp.digicert.com)

.NOTES
    Author  : chen2023yi
    Version : 1.0.0
    Repo    : https://github.com/chen2023yi/PyAppRelease
#>

# Packaging guideline annotations (per 桌面软件打包与发布规范.md):
# - Dynamic path mechanism: discover tools via environment variables (ProgramFiles, LocalAppData)
#   and use project-relative `OutputDir` for build artifacts. GUI logs are written to
#   the per-user LocalApplicationData\PyAppRelease folder (no writable files under install dir).
# - Core module protection: for production builds consider AOT/compilation (Nuitka/Cython)
#   or obfuscation for core business logic. The pipeline includes hooks where a
#   `UseAOT`/`UseNuitka` configuration flag can be supported to switch strategies.
# - User data mapping: runtime writable data (logs, DB, settings) must target
#   `%APPDATA%` or `%LOCALAPPDATA%`, not the program installation directory.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# Private helpers
# =============================================================================

function Write-ReleaseStep([string]$msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Write-ReleaseOK([string]$msg) {
    Write-Host "    [OK]   $msg" -ForegroundColor Green
}

function Write-ReleaseWarn([string]$msg) {
    Write-Host "    [WARN] $msg" -ForegroundColor Yellow
}

function Write-ReleaseSkip([string]$msg) {
    Write-Host "    [SKIP] $msg" -ForegroundColor DarkGray
}

function Invoke-ReleaseCmd([string]$desc, [scriptblock]$cmd, [bool]$dry) {
    if ($dry) {
        Write-Host "    [DRY]  $desc" -ForegroundColor DarkYellow
        return
    }
    & $cmd
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "'$desc' failed with exit code $LASTEXITCODE"
    }
}

function Get-SignToolPath {
    $cmd = Get-Command signtool -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # Search Windows SDK installations using environment-aware locations.
    # Avoid hard-coded developer-machine paths; prefer ProgramFiles env vars.
    $candidates = @()
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin' }
    if ($env:ProgramFiles)        { $candidates += Join-Path $env:ProgramFiles 'Windows Kits\10\bin' }

    foreach ($base in $candidates) {
        if (Test-Path $base) {
            $found = Get-ChildItem $base -Filter 'signtool.exe' -Recurse -ErrorAction SilentlyContinue |
                     Where-Object { $_.FullName -match 'x64' } |
                     Sort-Object LastWriteTime -Descending |
                     Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return $null
}

function Get-IsccPath {
    # Prefer environment-aware paths; do not hardcode machine-specific roots.
    $candidates = @()
    if ($env:LOCALAPPDATA) { $candidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' }
    if (${env:ProgramFiles(x86)}) { $candidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
    if ($env:ProgramFiles)        { $candidates += Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe' }

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command iscc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-SignFile([string]$filePath, [bool]$dry) {
    $signtool = Get-SignToolPath
    if (-not $signtool) {
        Write-ReleaseWarn "signtool.exe not found — skipping signing of $(Split-Path $filePath -Leaf)"
        return
    }

    $tsUrl = if ($env:PYAPP_SIGN_TIMESTAMP) { $env:PYAPP_SIGN_TIMESTAMP }
             else { "http://timestamp.digicert.com" }

    $signArgs = @("sign", "/fd", "sha256", "/tr", $tsUrl, "/td", "sha256")

    if ($env:PYAPP_SIGN_THUMBPRINT) {
        $signArgs += @("/sha1", $env:PYAPP_SIGN_THUMBPRINT)
    } elseif ($env:PYAPP_SIGN_PFX -and $env:PYAPP_SIGN_PASSWORD) {
        $signArgs += @("/f", $env:PYAPP_SIGN_PFX, "/p", $env:PYAPP_SIGN_PASSWORD)
    } else {
        Write-ReleaseWarn "No signing certificate configured (PYAPP_SIGN_THUMBPRINT or PYAPP_SIGN_PFX+PYAPP_SIGN_PASSWORD)"
        return
    }

    $signArgs += $filePath
    Invoke-ReleaseCmd "Sign $(Split-Path $filePath -Leaf)" { & $signtool @signArgs } $dry
    if (-not $dry) { Write-ReleaseOK "Signed: $(Split-Path $filePath -Leaf)" }
}

function New-PeVersionFile {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [string]$path,
        [string]$version,
        [string]$appName,
        [string]$displayName,
        [string]$description,
        [string]$company
    )
    $parts = $version -split '\.'
    while ($parts.Count -lt 4) { $parts += "0" }
    $tuple = "$($parts[0]), $($parts[1]), $($parts[2]), $($parts[3])"
    $year  = (Get-Date).Year

    @"
VSVersionInfo(
  ffi=FixedFileInfo(
    filevers=($tuple),
    prodvers=($tuple),
    mask=0x3f,
    flags=0x0,
    OS=0x4,
    fileType=0x1,
    subtype=0x0,
    date=(0, 0)
  ),
  kids=[
    StringFileInfo([
      StringTable(
        u'040904B0',
        [StringStruct(u'CompanyName', u'$company'),
         StringStruct(u'FileDescription', u'$description'),
         StringStruct(u'FileVersion', u'$version'),
         StringStruct(u'InternalName', u'$appName'),
         StringStruct(u'LegalCopyright', u'Copyright (C) $year $company'),
         StringStruct(u'OriginalFilename', u'$appName.exe'),
         StringStruct(u'ProductName', u'$displayName'),
         StringStruct(u'ProductVersion', u'$version')])
    ]),
    VarFileInfo([VarStruct(u'Translation', [0x0409, 1200])])
  ]
)
"@ | Set-Content -Path $path -Encoding UTF8
}

function New-AutoInnoScript {
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [string]$Path,
        [string]$AppName,
        [string]$DisplayName,
        [string]$Company,
        [string]$Version,
        [bool]$OneFile
    )

    $publisher = if ($Company) { $Company } else { $DisplayName }
    $filesSection = if ($OneFile) {
        "Source: `"{#DistDir}\\{#AppName}.exe`"; DestDir: `"{app}`"; Flags: ignoreversion"
    } else {
        "Source: `"{#DistDir}\\*`"; DestDir: `"{app}`"; Flags: ignoreversion recursesubdirs createallsubdirs"
    }

    @"
; Auto-generated by PyAppRelease when InnoScript is not configured
#define AppPublisher "$publisher"

[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\\{#AppName}
DefaultGroupName={#AppName}
OutputBaseFilename={#AppName}_Setup_{#AppVersion}
OutputDir={#OutputDir}
Compression=lzma
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a desktop icon"; GroupDescription: "Additional icons:"; Flags: unchecked

[Files]
$filesSection

[Icons]
Name: "{group}\\{#AppName}"; Filename: "{app}\\{#AppName}.exe"
Name: "{autodesktop}\\{#AppName}"; Filename: "{app}\\{#AppName}.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\\{#AppName}.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
"@ | Set-Content -Path $Path -Encoding UTF8
}

# =============================================================================
# Public: Invoke-PyAppRelease
# =============================================================================

function Invoke-PyAppRelease {
<#
.SYNOPSIS
    Run the full release pipeline for a Python desktop application.

.DESCRIPTION
    Reads project settings from a release.config.psd1 file, bumps the version,
    builds the EXE with PyInstaller, creates an Inno Setup installer (uses a
    generated default script when InnoScript is omitted),
    signs both artifacts, generates a SHA-256 checksum, and creates a git tag.

.PARAMETER ConfigFile
    Path to the release.config.psd1 file. Resolved relative to the current directory.
    Default: "release.config.psd1"

.PARAMETER BumpMajor
    Increment major version and reset minor + patch to 0.

.PARAMETER BumpMinor
    Increment minor version and reset patch to 0.

.PARAMETER BumpPatch
    Increment patch version. This is the default when no bump flag is given.

.PARAMETER VersionOverride
    Set an exact version string (e.g. "2.0.0"). Skips all bump logic.

.PARAMETER SkipSign
    Skip code-signing even if certificate environment variables are set.

.PARAMETER SkipGitTag
    Do not create or push a git tag.

.PARAMETER SkipGitPush
    Create the git tag locally but do not push it to the remote.

.PARAMETER DryRun
    Print what would happen without executing any build, sign, or git actions.

.EXAMPLE
    # Default patch bump (1.0.0 -> 1.0.1)
    Invoke-PyAppRelease

.EXAMPLE
    # Minor bump with custom config path
    Invoke-PyAppRelease -BumpMinor -ConfigFile .\my_app.release.psd1

.EXAMPLE
    # Pin an exact version, skip git, preview only
    Invoke-PyAppRelease -VersionOverride 2.0.0 -SkipGitTag -DryRun
#>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [string]$ConfigFile      = "release.config.psd1",
        [switch]$BumpMajor,
        [switch]$BumpMinor,
        [switch]$BumpPatch,
        [string]$VersionOverride = "",
        [switch]$SkipSign,
        [switch]$SkipGitTag,
        [switch]$SkipGitPush,
        [switch]$DryRun
    )

    $ProjectRoot = (Get-Location).Path
    $cfgPath = if ([System.IO.Path]::IsPathRooted($ConfigFile)) { $ConfigFile }
               else { Join-Path $ProjectRoot $ConfigFile }

    if (-not (Test-Path $cfgPath)) {
        # Try alternative location inside the project's output folder (release/)
        $altDir  = Join-Path $ProjectRoot 'release'
        $altCfg  = Join-Path $altDir 'release.config.psd1'
        if (Test-Path $altCfg) {
            Write-ReleaseWarn "Found config at alternate location: $altCfg"
            $cfgPath = $altCfg
        } else {
            # Auto-create a sensible default config inside release/ for new projects
            Write-ReleaseWarn "Release config not found: $cfgPath"
            Write-ReleaseWarn "Creating default config at: $altCfg"
            if (-not (Test-Path $altDir)) { New-Item -ItemType Directory -Path $altDir -Force | Out-Null }
            $defaultAppName = Split-Path -Leaf $ProjectRoot
            # Create a minimal PSD1 template directly to avoid invoking the
            # higher-level scaffolder (avoids side effects in CI/UI).
            $psd1Template = @'
@{
    AppName        = "{APPNAME}"
    DisplayName    = "{APPNAME}"
    Description    = "{APPNAME}"
    Company        = ""

    EntryScript    = "main.py"
    VenvPython     = ".venv\Scripts\python.exe"

    Windowed       = $true
    OneFile        = $false
    CollectAll     = @()
    HiddenImports  = @()
    ExtraArgs      = @()

    OutputDir      = "release"
    GitRemote      = "origin"
    TagPrefix      = "v"
}
'@
            $defaultSafe = $defaultAppName -replace '"','\"'
            $psd1 = $psd1Template -replace '\{APPNAME\}',$defaultSafe
            try {
                $psd1 | Set-Content -Path $altCfg -Encoding UTF8
                Write-ReleaseOK "Created default release config: $altCfg"
                $cfgPath = $altCfg
            } catch {
                throw "Failed to create default release.config.psd1: $_"
            }
        }
    }

    $cfg = Import-PowerShellDataFile $cfgPath

    # ── Resolve config with defaults ──────────────────────────────────────────
    function Cfg([string]$key, [object]$default) {
        if ($cfg.ContainsKey($key) -and $null -ne $cfg[$key]) { return $cfg[$key] }
        return $default
    }

    $AppName        = $cfg.AppName                              # required
    $DisplayName    = Cfg 'DisplayName'    $AppName
    $Description    = Cfg 'Description'   $DisplayName
    $Company        = Cfg 'Company'        ''
    $EntryScript    = Cfg 'EntryScript'   'main.py'
    $VenvPython     = Cfg 'VenvPython'    '.venv\Scripts\python.exe'
    $VersionFile    = Cfg 'VersionFile'   'VERSION'
    $InnoScript     = Cfg 'InnoScript'    ''
    $InnoDefines    = Cfg 'InnoDefines'   @{}
    $OutputDir      = Cfg 'OutputDir'     'release'
    $GitRemote      = Cfg 'GitRemote'     'origin'
    $TagPrefix      = Cfg 'TagPrefix'     'v'
    $Windowed       = Cfg 'Windowed'      $true
    $OneFile        = Cfg 'OneFile'       $false
    $CollectAll     = Cfg 'CollectAll'    @()
    $HiddenImports  = Cfg 'HiddenImports' @()
    $ExtraArgs      = Cfg 'ExtraArgs'     @()

    if (-not $AppName) { throw "release.config.psd1 must specify AppName." }

    # ── Resolve Python executable ──────────────────────────────────────────────
    # Priority: config VenvPython → common venv paths → system python
    $pythonExe = $null
    $configuredPath = Join-Path $ProjectRoot $VenvPython
    if (Test-Path $configuredPath) {
        $pythonExe = $configuredPath
    } else {
        # Search common virtual-environment locations
        $candidates = @(
            '.venv\Scripts\python.exe',
            'venv\Scripts\python.exe',
            '.env\Scripts\python.exe',
            'env\Scripts\python.exe'
        ) | ForEach-Object { Join-Path $ProjectRoot $_ }
        foreach ($c in $candidates) {
            if (Test-Path $c) { $pythonExe = $c; break }
        }
        # Fallback: system Python on PATH
        if (-not $pythonExe) {
            $sysPy = Get-Command python -ErrorAction SilentlyContinue |
                     Select-Object -First 1 -ExpandProperty Source
            if ($sysPy -and (Test-Path $sysPy)) { $pythonExe = $sysPy }
        }
    }
    if (-not $pythonExe) {
        throw "Python not found.`nLooked for: $configuredPath`nAlso checked: .venv, venv, .env, env, system PATH.`nCreate a virtual environment or install Python."
    }
    Write-ReleaseOK "Python: $pythonExe"

    $outputDirPath   = Join-Path $ProjectRoot $OutputDir

    # All generated / intermediate files go into the release folder
    # so the source tree stays clean.
    if (-not (Test-Path $outputDirPath)) {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($outputDirPath, 'Create directory')) {
            New-Item -ItemType Directory -Path $outputDirPath -Force | Out-Null
        } else {
            Write-ReleaseSkip "Create dir $outputDirPath (WhatIf)"
        }
    }
    $versionFilePath = Join-Path $outputDirPath "VERSION"

    # ── 1. Version management ─────────────────────────────────────────────────
    Write-ReleaseStep "Version management"

    if (-not (Test-Path $versionFilePath)) {
        # Also check the legacy location in project root for migration
        $legacyVerPath = Join-Path $ProjectRoot $VersionFile
            if (Test-Path $legacyVerPath) {
            $currentVersion = (Get-Content $legacyVerPath -Raw).Trim()
            if ($currentVersion -match '^\d+\.\d+\.\d+$') {
                Write-ReleaseWarn "Migrating VERSION from project root to $OutputDir/"
                if (-not $DryRun) {
                    if ($PSCmdlet -and $PSCmdlet.ShouldProcess($versionFilePath, 'Write VERSION')) {
                        Set-Content -Path $versionFilePath -Value $currentVersion -Encoding UTF8
                    } else {
                        Write-ReleaseSkip "Write VERSION $versionFilePath (WhatIf)"
                    }
                }
            } else {
                throw "VERSION file must contain a semantic version (e.g. 1.0.0). Got: '$currentVersion'"
            }
        } else {
            Write-ReleaseWarn "VERSION file not found — initializing to 0.0.0"
            $currentVersion = '0.0.0'
            if (-not $DryRun) {
                if ($PSCmdlet -and $PSCmdlet.ShouldProcess($versionFilePath, 'Write VERSION')) {
                    Set-Content -Path $versionFilePath -Value '0.0.0' -Encoding UTF8
                } else {
                    Write-ReleaseSkip "Write VERSION $versionFilePath (WhatIf)"
                }
            }
        }
    } else {
        $currentVersion = (Get-Content $versionFilePath -Raw).Trim()
        if ($currentVersion -notmatch '^\d+\.\d+\.\d+$') {
            throw "VERSION file must contain a semantic version (e.g. 1.0.0). Got: '$currentVersion'"
        }
    }

    $p = $currentVersion -split '\.'; [int]$ma = $p[0]; [int]$mi = $p[1]; [int]$pa = $p[2]

    if ($VersionOverride -ne '') {
        if ($VersionOverride -notmatch '^\d+\.\d+\.\d+$') {
            throw "-VersionOverride must be semver (e.g. 2.0.0). Got: '$VersionOverride'"
        }
        $newVersion = $VersionOverride
    } elseif ($BumpMajor) { $newVersion = "$($ma+1).0.0" }
    elseif  ($BumpMinor)  { $newVersion = "$ma.$($mi+1).0" }
    elseif  ($BumpPatch)  { $newVersion = "$ma.$mi.$($pa+1)" }
    else                  { $newVersion = "$ma.$mi.$($pa+1)" }   # default: patch

    Write-Host "    Current : $currentVersion"
    Write-Host "    New     : $newVersion"

    if (-not $DryRun) {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($versionFilePath, 'Update VERSION')) {
            Set-Content -Path $versionFilePath -Value $newVersion -Encoding UTF8
        } else {
            Write-ReleaseSkip "Update VERSION $versionFilePath (WhatIf)"
        }
    }
    Write-ReleaseOK "VERSION -> $newVersion"

    # ── 2. Build application bundle (PyInstaller) ─────────────────────────────
    Write-ReleaseStep "Building application bundle (PyInstaller)"

    # PyInstaller output directories go into the release folder
    $piBuildDir = Join-Path $outputDirPath "build"
    $piDistDir  = Join-Path $outputDirPath "dist"
    $distDir    = Join-Path $piDistDir $AppName
    $mainExe    = if ($OneFile) { Join-Path $piDistDir "$AppName.exe" }
                  else          { Join-Path $distDir "$AppName.exe" }

    if (-not $DryRun) {
        # Upgrade PyInstaller quietly. Keep warnings visible but do not treat
        # native stderr text as terminating PowerShell errors.
        $oldEap = $ErrorActionPreference
        $pipExit = 0
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($pythonExe, 'Install/upgrade pyinstaller')) {
            try {
                $ErrorActionPreference = "Continue"
                & $pythonExe -m pip install --quiet --upgrade pyinstaller 2>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        $msg = $_.ToString().Trim()
                        if ($msg) { Write-ReleaseWarn $msg }
                    } else {
                        $_
                    }
                }
                $pipExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldEap
            }
        } else {
            Write-ReleaseSkip "pip install pyinstaller (WhatIf)"
            $pipExit = 0
        }
        if ($pipExit -and $pipExit -ne 0) {
            throw "pip install pyinstaller failed with exit code $pipExit"
        }

        # Generate Windows PE version-info file inside release folder (never in source)
        $verInfoPath = Join-Path $outputDirPath "_pyapprelease_version.txt"
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($verInfoPath, 'Generate version info file')) {
            New-PeVersionFile -path        $verInfoPath `
                              -version     $newVersion `
                              -appName     $AppName `
                              -displayName $DisplayName `
                              -description $Description `
                              -company     $Company
        } else {
            Write-ReleaseSkip "Generate version info file (WhatIf)"
        }

        # Assemble PyInstaller arguments
        $piArgs = @("-m", "PyInstaller", "--noconfirm", "--clean")
        if ($Windowed) { $piArgs += "--windowed" }
        if ($OneFile)  { $piArgs += "--onefile"  }
        $piArgs += @("--name", $AppName)
        $piArgs += @("--distpath", $piDistDir)
        $piArgs += @("--workpath", $piBuildDir)
        $piArgs += @("--specpath", $outputDirPath)
        foreach ($pkg in $CollectAll)    { $piArgs += @("--collect-all",   $pkg) }
        foreach ($hi  in $HiddenImports) { $piArgs += @("--hidden-import", $hi)  }
        $piArgs += @("--version-file", $verInfoPath)
        $piArgs += $ExtraArgs
        $piArgs += $EntryScript

        $pyiExit = 0
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($ProjectRoot, 'Run PyInstaller build')) {
            Push-Location $ProjectRoot
            $oldEap = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                & $pythonExe @piArgs 2>&1 | ForEach-Object {
                    if ($_ -is [System.Management.Automation.ErrorRecord]) {
                        $msg = $_.ToString().Trim()
                        if ($msg) { Write-ReleaseWarn $msg }
                    } else {
                        $_
                    }
                }
                $pyiExit = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $oldEap
                Pop-Location
                if ($PSCmdlet -and $PSCmdlet.ShouldProcess($verInfoPath, 'Remove temp version file')) {
                    Remove-Item $verInfoPath -ErrorAction SilentlyContinue
                } else {
                    Write-ReleaseSkip "Remove $verInfoPath (WhatIf)"
                }
            }
        } else {
            Write-ReleaseSkip "PyInstaller build (WhatIf)"
        }

        if ($pyiExit -and $pyiExit -ne 0) {
            throw "PyInstaller failed with exit code $pyiExit"
        }
        if (-not (Test-Path $mainExe)) { throw "Expected EXE not found: $mainExe" }
    } else {
        Write-Host "    [DRY]  PyInstaller build: $AppName v$newVersion" -ForegroundColor DarkYellow
    }

    Write-ReleaseOK "Application bundle built"

    # ── 3. Sign main EXE ──────────────────────────────────────────────────────
    Write-ReleaseStep "Code signing: main EXE"
    if ($SkipSign) { Write-ReleaseSkip "Signing skipped (-SkipSign)" }
    else {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($mainExe, 'Sign main EXE')) {
            Invoke-SignFile $mainExe $DryRun.IsPresent
        } else {
            Write-ReleaseSkip "Sign main EXE (WhatIf)"
        }
    }

    # ── 4. Build installer (Inno Setup) ───────────────────────────────────────
    Write-ReleaseStep "Building installer (Inno Setup)"

    $installerPath = ""
    $issPath = ""
    $autoIss = $false

    if ($InnoScript -eq '') {
        $issPath = Join-Path $outputDirPath '_pyapprelease_auto.iss'
        $autoIss = $true
        Write-ReleaseWarn "InnoScript not configured — generating default installer script"
        if (-not $DryRun) {
            if ($PSCmdlet -and $PSCmdlet.ShouldProcess($issPath, 'Generate default Inno Setup script')) {
                New-AutoInnoScript -Path $issPath `
                                   -AppName $AppName `
                                   -DisplayName $DisplayName `
                                   -Company $Company `
                                   -Version $newVersion `
                                   -OneFile ([bool]$OneFile)
            } else {
                Write-ReleaseSkip "Generate default Inno Setup script (WhatIf)"
            }
        }
    } else {
        $issPath = if ([System.IO.Path]::IsPathRooted($InnoScript)) { $InnoScript }
                   else { Join-Path $ProjectRoot $InnoScript }
    }

    if (-not $DryRun -and -not (Test-Path $issPath)) { throw "Inno Setup script not found: $issPath" }

    $iscc = Get-IsccPath
    if (-not $iscc) { throw "ISCC.exe not found. Install Inno Setup 6: https://jrsoftware.org/isdl.php" }

    # Standard defines — always passed
    $isccArgs = @(
        "/DAppVersion=$newVersion",
        "/DAppName=$AppName",
        "/DDistDir=$distDir",
        "/DOutputDir=$outputDirPath"
    )

    # Extra project-specific defines from config
    foreach ($key in $InnoDefines.Keys) {
        $val = $InnoDefines[$key] -replace '\{Version\}', $newVersion `
                                  -replace '\{AppName\}', $AppName `
                                  -replace '\{DistDir\}', $distDir
        $isccArgs += "/D${key}=${val}"
    }

    $isccArgs += $issPath

    # Record timestamp before build to identify new installer
    $buildStart = Get-Date

    $isccDesc = "ISCC $(Split-Path $issPath -Leaf) /DAppVersion=$newVersion"
    if ($PSCmdlet -and $PSCmdlet.ShouldProcess($issPath, 'Run ISCC')) {
        Invoke-ReleaseCmd $isccDesc {
            & $iscc @isccArgs
        } $DryRun.IsPresent
    } else {
        Write-ReleaseSkip "$isccDesc (WhatIf)"
    }

    if (-not $DryRun) {
        # Find the installer produced by this run
        $installerPath = Get-ChildItem $outputDirPath -Filter "*.exe" -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -ge $buildStart } |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1 -ExpandProperty FullName

        if (-not $installerPath) { throw "No installer .exe found in: $outputDirPath" }
        Write-ReleaseOK "Installer: $(Split-Path $installerPath -Leaf)"
    } else {
        $installerPath = Join-Path $outputDirPath "${AppName}_Setup_${newVersion}.exe"
        Write-Host "    [DRY]  Expected: $(Split-Path $installerPath -Leaf)" -ForegroundColor DarkYellow
    }

    if ($autoIss -and -not $DryRun) {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($issPath, 'Remove generated Inno Setup script')) {
            Remove-Item $issPath -ErrorAction SilentlyContinue
        } else {
            Write-ReleaseSkip "Remove generated Inno Setup script (WhatIf)"
        }
    }

    # ── 5. Sign installer ─────────────────────────────────────────────────────
    Write-ReleaseStep "Code signing: installer"
    if ($SkipSign -or $installerPath -eq '') {
        Write-ReleaseSkip "Signing skipped"
    } else {
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($installerPath, 'Sign installer')) {
            Invoke-SignFile $installerPath $DryRun.IsPresent
        } else {
            Write-ReleaseSkip "Sign installer (WhatIf)"
        }
    }

    # ── 6. SHA-256 checksum ───────────────────────────────────────────────────
    Write-ReleaseStep "Generating SHA-256 checksum"
    $checksumPath = ""
    if ($installerPath -ne '') {
        $checksumPath = $installerPath -replace '\.exe$', '.sha256'
        $shaDesc = "SHA256 $(Split-Path $installerPath -Leaf)"
        if ($PSCmdlet -and $PSCmdlet.ShouldProcess($checksumPath, 'Generate SHA-256 checksum')) {
            Invoke-ReleaseCmd $shaDesc {
                $hash = (Get-FileHash $installerPath -Algorithm SHA256).Hash
                "$hash  $(Split-Path $installerPath -Leaf)" |
                    Set-Content $checksumPath -Encoding UTF8
            } $DryRun.IsPresent
            if (-not $DryRun) { Write-ReleaseOK "Checksum: $(Split-Path $checksumPath -Leaf)" }
        } else {
            Write-ReleaseSkip "$shaDesc (WhatIf)"
        }
    } else {
        Write-ReleaseSkip "No installer — checksum skipped"
    }

    # ── 7. Git commit + tag ───────────────────────────────────────────────────
    Write-ReleaseStep "Git: commit and tag"
    $tagName = "${TagPrefix}${newVersion}"

    if ($SkipGitTag) {
        Write-ReleaseSkip "Git tagging skipped (-SkipGitTag)"
    } else {
        # VERSION is now inside the release output folder
        $relVerPath = Join-Path $OutputDir "VERSION"

        # Native git commands may write warnings to stderr; do not fail on stderr text.
        $oldEap = $ErrorActionPreference
        $isGitRepo = $false
        $isVersionIgnored = $false
        try {
            $ErrorActionPreference = "Continue"
            git -C $ProjectRoot rev-parse --is-inside-work-tree 2>$null | Out-Null
            $isGitRepo = ($LASTEXITCODE -eq 0)
            if ($isGitRepo) {
                git -C $ProjectRoot check-ignore -q -- $relVerPath 2>$null
                $isVersionIgnored = ($LASTEXITCODE -eq 0)
            }
        } finally {
            $ErrorActionPreference = $oldEap
        }

        if (-not $isGitRepo) {
            Write-ReleaseWarn "Not a git repository: skipping commit/tag/push"
            Write-ReleaseSkip "Git tagging skipped (not a git repo)"
        } elseif ($isVersionIgnored) {
            Write-ReleaseWarn "$relVerPath is ignored by .gitignore; skipping commit/tag/push"
            Write-ReleaseSkip "Git tagging skipped (VERSION ignored)"
        } else {
            $gitAddDesc = "git add $relVerPath"
            if ($PSCmdlet -and $PSCmdlet.ShouldProcess($relVerPath, 'Git add VERSION')) {
                Invoke-ReleaseCmd $gitAddDesc {
                    git -C $ProjectRoot add -- $relVerPath
                } $DryRun.IsPresent
            } else {
                Write-ReleaseSkip "$gitAddDesc (WhatIf)"
            }

            # If nothing is staged after adding VERSION, skip commit/tag gracefully.
            $hasStaged = $true
            if (-not $DryRun) {
                $oldEap = $ErrorActionPreference
                try {
                    $ErrorActionPreference = "Continue"
                    git -C $ProjectRoot diff --cached --quiet --
                    $hasStaged = ($LASTEXITCODE -ne 0)
                } finally {
                    $ErrorActionPreference = $oldEap
                }
            }

            if (-not $hasStaged) {
                Write-ReleaseWarn "No staged changes to commit after adding $relVerPath"
                Write-ReleaseSkip "Git tagging skipped (nothing to commit)"
            } else {
                $gitCommitDesc = "git commit -m 'chore: release $tagName'"
                if ($PSCmdlet -and $PSCmdlet.ShouldProcess($relVerPath, 'Git commit')) {
                    Invoke-ReleaseCmd $gitCommitDesc {
                        git -C $ProjectRoot commit -m "chore: release $tagName"
                    } $DryRun.IsPresent
                } else {
                    Write-ReleaseSkip "$gitCommitDesc (WhatIf)"
                }

                $gitTagDesc = "git tag -a $tagName -m 'Release $tagName'"
                if ($PSCmdlet -and $PSCmdlet.ShouldProcess($tagName, 'Git tag')) {
                    Invoke-ReleaseCmd $gitTagDesc {
                        git -C $ProjectRoot tag -a $tagName -m "Release $tagName"
                    } $DryRun.IsPresent
                } else {
                    Write-ReleaseSkip "$gitTagDesc (WhatIf)"
                }

                Write-ReleaseOK "Tagged: $tagName"

                if (-not $SkipGitPush) {
                    $gitPushDesc = "git push $GitRemote HEAD --tags"
                    if ($PSCmdlet -and $PSCmdlet.ShouldProcess($ProjectRoot, 'Git push')) {
                        Invoke-ReleaseCmd $gitPushDesc {
                            git -C $ProjectRoot push $GitRemote HEAD --tags
                        } $DryRun.IsPresent
                    } else {
                        Write-ReleaseSkip "$gitPushDesc (WhatIf)"
                    }
                    if (-not $DryRun) { Write-ReleaseOK "Pushed to $GitRemote" }
                } else {
                    Write-ReleaseSkip "Git push skipped (-SkipGitPush)"
                }
            }
        }
    }

    # ── Summary ───────────────────────────────────────────────────────────────
    Write-Host ""
    Write-Host "-----------------------------------------------------" -ForegroundColor Green
    Write-Host "  Release complete: $DisplayName  v$newVersion"        -ForegroundColor Green
    if ($installerPath -ne '' -and -not $DryRun) {
        $rel = $installerPath.Replace($ProjectRoot, '').TrimStart('\','/')
        Write-Host "  Installer : $rel"                                -ForegroundColor Green
    }
    if ($checksumPath -ne '' -and -not $DryRun) {
        $rel = $checksumPath.Replace($ProjectRoot, '').TrimStart('\','/')
        Write-Host "  Checksum  : $rel"                                -ForegroundColor Green
    }
    Write-Host "  Git tag   : $tagName"                                -ForegroundColor Green
    Write-Host "-----------------------------------------------------" -ForegroundColor Green
}

# =============================================================================
# Public: New-PyAppReleaseConfig
# =============================================================================

function New-PyAppReleaseConfig {
<#
.SYNOPSIS
    Scaffold a release.config.psd1 for a new project.

.PARAMETER AppName
    PyInstaller --name value and output EXE name. Required.

.PARAMETER DisplayName
    Human-readable name used in installer titles and version metadata.
    Defaults to AppName.

.PARAMETER Description
    File description embedded in the EXE metadata. Defaults to DisplayName.

.PARAMETER Company
    Company / author name embedded in metadata and copyright string.

.PARAMETER EntryScript
    Python entry-point passed to PyInstaller. Default: main.py

.PARAMETER InnoScript
    Relative path to the .iss file. Omit if not using Inno Setup.

.PARAMETER Path
    Output path for the generated config file. Default: release.config.psd1

.PARAMETER Force
    Overwrite an existing config file.

.EXAMPLE
    New-PyAppReleaseConfig -AppName MyTool -Company Acme -InnoScript installer\MyTool.iss
#>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param(
        [Parameter(Mandatory)]
        [string]$AppName,
        [string]$DisplayName  = "",
        [string]$Description  = "",
        [string]$Company      = "",
        [string]$EntryScript  = "main.py",
        [string]$InnoScript   = "",
        [string]$Path         = "release.config.psd1",
        [switch]$Force
    )

    if ((Test-Path $Path) -and -not $Force) {
        throw "Config file already exists: $Path. Use -Force to overwrite."
    }

    if ($DisplayName -eq '') { $DisplayName = $AppName }
    if ($Description -eq '')  { $Description  = $DisplayName }

    $innoLine = if ($InnoScript) {
        "    InnoScript     = `"$InnoScript`""
    } else {
        "    # InnoScript   = `"installer\$AppName.iss`"   # uncomment when ready"
    }

    @"
# release.config.psd1 — PyAppRelease project configuration
# Run the pipeline: Invoke-PyAppRelease  (patch bump, default)
#                   Invoke-PyAppRelease -BumpMinor
#                   Invoke-PyAppRelease -VersionOverride 2.0.0 -DryRun
@{
    # ── Application identity ───────────────────────────────────────────────────
    AppName        = "$AppName"         # PyInstaller --name; also used as EXE filename
    DisplayName    = "$DisplayName"     # Human-readable name (installer, metadata)
    Description    = "$Description"    # Short description embedded in EXE properties
    Company        = "$Company"         # Author / company (copyright string)

    # ── Build environment ──────────────────────────────────────────────────────
    EntryScript    = "$EntryScript"     # Python entry point passed to PyInstaller
    VenvPython     = ".venv\Scripts\python.exe"   # auto-detects .venv, venv, .env, env, or system python

    # ── PyInstaller options ────────────────────────────────────────────────────
    Windowed       = `$true             # `$false = keep console window
    OneFile        = `$false            # `$true = single .exe (slower startup)
    CollectAll     = @()               # e.g. @("pyqtgraph", "numpy")
    HiddenImports  = @()               # e.g. @("sitecustomize")
    ExtraArgs      = @()               # any extra PyInstaller CLI flags

    # ── Installer (Inno Setup) ─────────────────────────────────────────────────
$innoLine
    OutputDir      = "release"          # All build output: VERSION, dist, installer, checksum

    # ── Git ────────────────────────────────────────────────────────────────────
    GitRemote      = "origin"
    TagPrefix      = "v"                # git tag = "v1.2.3"

    # ── Extra Inno Setup /D defines (optional) ─────────────────────────────────
    # InnoDefines  = @{ MyCustomDefine = "value" }
    # Placeholders: {Version}, {AppName}, {DistDir}
}
"@ | Set-Content -Path $Path -Encoding UTF8

    Write-Host "Created: $Path" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Edit $Path to match your project"
    Write-Host "  2. Run: Invoke-PyAppRelease -DryRun"
    Write-Host "  (VERSION file will be auto-created in the release/ folder on first run)"
}

# =============================================================================
# Public: Start-PyAppReleaseGUI
# =============================================================================

function Start-PyAppReleaseGUI {
<#
.SYNOPSIS
    Open the PyAppRelease graphical release tool.

.DESCRIPTION
    Launches the WinForms GUI. The current directory (or the -ProjectDir
    argument) is pre-filled in the Project Folder field.

.PARAMETER ProjectDir
    Pre-fill the project folder on launch. Defaults to the current directory
    when it contains release.config.psd1.

.EXAMPLE
    # From a project folder:
    Start-PyAppReleaseGUI

    # Explicit path:
    Start-PyAppReleaseGUI -ProjectDir "C:\Projects\MyApp"
#>
    [CmdletBinding(SupportsShouldProcess=$true)]
    param([string]$ProjectDir = "")

    $guiScript = Join-Path (Split-Path -Parent $PSCommandPath) "PyAppRelease-GUI.ps1"
    if (-not (Test-Path $guiScript)) {
        throw "GUI script not found: $guiScript`nEnsure PyAppRelease-GUI.ps1 is in the same folder as the module."
    }

    # Launch the GUI in a separate process.
    $launchArgs = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$guiScript`""
    if ($ProjectDir) { $launchArgs += " -ProjectDir `"$ProjectDir`"" }
    if ($PSCmdlet -and -not $PSCmdlet.ShouldProcess($guiScript, 'Launch GUI')) {
        Write-ReleaseSkip "Launch GUI (WhatIf)"
        return
    }
    Start-Process powershell.exe -ArgumentList $launchArgs
}

Export-ModuleMember -Function Invoke-PyAppRelease, New-PyAppReleaseConfig, Start-PyAppReleaseGUI
