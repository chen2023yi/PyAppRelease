#Requires -Version 5.1
param([string]$ProjectDir = "")

if (-not $ProjectDir -and $env:PYAPP_PROJECT_DIR) {
    $ProjectDir = $env:PYAPP_PROJECT_DIR
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Log files are written to the user's application data directory to comply
# with "read-write data area" rules (no writable data under the install dir).
# Dynamic path mechanism: logs are placed under the current user's
# LocalApplicationData\PyAppRelease folder so they are per-user and portable.
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')
$logDir = Join-Path $localAppData 'PyAppRelease'
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
$script:ErrorLogFile = Join-Path $logDir "PyAppRelease_GUI_error.txt"
$script:TraceLogFile = Join-Path $logDir "PyAppRelease_GUI_trace.txt"

# STA check - WinForms requires Single-Threaded Apartment
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-TraceLog "Startup" "Not STA. Relaunching under STA."
    $a = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$($MyInvocation.MyCommand.Path)`""
    if ($ProjectDir) { $a += " -ProjectDir `"$ProjectDir`"" }
    Start-Process powershell.exe -ArgumentList $a
    exit
}

function Write-ErrorLog([string]$source, [object]$errorObject) {
    try {
        $detail = if ($errorObject -is [System.Management.Automation.ErrorRecord]) {
            $errorObject | Out-String
        } elseif ($errorObject -is [System.Exception]) {
            $errorObject.ToString()
        } else {
            [string]$errorObject
        }
        $msg = "TIME: $(Get-Date)`nSOURCE: $source`nDETAIL:`n$detail`n---`n"
        [IO.File]::AppendAllText($script:ErrorLogFile, $msg)
    } catch {}
}

function Write-TraceLog([string]$source, [string]$message) {
    try {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$PID] [$source] $message`r`n"
        [IO.File]::AppendAllText($script:TraceLogFile, $line)
    } catch {}
}

try {
    [IO.File]::WriteAllText($script:TraceLogFile, "")
    Write-TraceLog "Startup" "Script entry. ProjectDir='$ProjectDir'"
    Write-TraceLog "Startup" ("PSBoundParameters=" + (($PSBoundParameters.Keys | ForEach-Object { $_ + '=' + [string]$PSBoundParameters[$_] }) -join ';'))
    Write-TraceLog "Startup" ("CommandLine=" + [Environment]::CommandLine)
    Write-TraceLog "Startup" ("InvocationLine=" + $MyInvocation.Line)
    Write-TraceLog "Startup" ("CurrentDirectory=" + (Get-Location).Path)
} catch {}

trap {
    Write-TraceLog "Trap" "Top-level trap fired."
    Write-ErrorLog "TopLevelTrap" $_
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "ERROR:`n$_`n`nLog: $script:ErrorLogFile", "PyAppRelease Error", "OK", "Error") | Out-Null
    } catch {}
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Hide the PowerShell console window; the WinForms window is separate and stays visible.
try {
    Add-Type -Name ConsoleWin -Namespace PyAppRelease -MemberDefinition @'
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $hConsole = [PyAppRelease.ConsoleWin]::GetConsoleWindow()
    if ($hConsole -ne [IntPtr]::Zero) {
        [PyAppRelease.ConsoleWin]::ShowWindow($hConsole, 0) | Out-Null   # SW_HIDE
    }
} catch {
    Write-TraceLog "HideConsole" "Could not hide console: $_"
}

[System.Windows.Forms.Application]::add_ApplicationExit({
    Write-TraceLog "ApplicationExit" "Application exit event fired."
})
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Write-TraceLog "ThreadException" $e.Exception.Message
    Write-ErrorLog "ThreadException" $e.Exception
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Unhandled UI error.`n`nLog: $script:ErrorLogFile", "PyAppRelease Error", "OK", "Error") | Out-Null
    } catch {}
})
[AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    Write-TraceLog "AppDomainUnhandledException" ([string]$e.IsTerminating)
    Write-ErrorLog "AppDomainUnhandledException" $e.ExceptionObject
})

function Find-ModulePath {
    $local = Join-Path $ScriptDir "PyAppRelease.psm1"
    if (Test-Path $local) { return $local }
    $m = Get-Module -ListAvailable -Name PyAppRelease -ErrorAction SilentlyContinue
    if ($m) { return $m[0].Path }
    return $null
}

function Read-ProjectInfo([string]$dir) {
    $r = @{ Valid=$false; Version=""; ConfigFound=$false; OutputDir="release"; AppName=""; VersionMissing=$false }
    if (-not $dir -or -not (Test-Path $dir -PathType Container)) { return $r }
    $cfgPath = Join-Path $dir "release.config.psd1"
    if (Test-Path $cfgPath) {
        $r.ConfigFound = $true
        try {
            $cfg = Import-PowerShellDataFile $cfgPath
            if ($cfg.ContainsKey("OutputDir") -and $cfg.OutputDir) { $r.OutputDir = $cfg.OutputDir }
            if ($cfg.ContainsKey("AppName")   -and $cfg.AppName)   { $r.AppName   = $cfg.AppName }
        } catch {}
    }
    # VERSION file lives inside the output (release) folder, not in the source root
    $verPath = Join-Path (Join-Path $dir $r.OutputDir) "VERSION"
    if (Test-Path $verPath) {
        $v = (Get-Content $verPath -Raw -ErrorAction SilentlyContinue).Trim()
        if ($v -match '^\d+\.\d+\.\d+$') { $r.Version = $v }
    } else {
        # Also check legacy location (project root) for migration
        $legacyVerPath = Join-Path $dir "VERSION"
        if (Test-Path $legacyVerPath) {
            $v = (Get-Content $legacyVerPath -Raw -ErrorAction SilentlyContinue).Trim()
            if ($v -match '^\d+\.\d+\.\d+$') { $r.Version = $v }
        } else {
            $r.Version = "0.0.0"
            $r.VersionMissing = $true
        }
    }
    $r.Valid = $r.ConfigFound -and [bool]$r.Version
    return $r
}

function Get-BumpedVersion([string]$ver, [string]$bump, [string]$custom) {
    if ($bump -eq "Custom") { return $custom }
    if ($ver -notmatch '^\d+\.\d+\.\d+$') { return "?" }
    $p = $ver -split '\.'; [int]$ma=$p[0]; [int]$mi=$p[1]; [int]$pa=$p[2]
    switch ($bump) {
        "Major" { return "$($ma+1).0.0" }
        "Minor" { return "$ma.$($mi+1).0" }
        default { return "$ma.$mi.$($pa+1)" }
    }
}

function Get-LineColor([string]$line) {
    if ($line -match '\[OK\]')                          { return [System.Drawing.Color]::LightGreen }
    if ($line -match '\[SKIP\]')                        { return [System.Drawing.Color]::DimGray }
    if ($line -match '\[WARN\]')                        { return [System.Drawing.Color]::Gold }
    if ($line -match '\[DRY\]')                         { return [System.Drawing.Color]::SkyBlue }
    if ($line -match '^==>|^-{20,}|Release complete')  { return [System.Drawing.Color]::Cyan }
    if ($line -match 'FAILED|^\[ERR\]')                 { return [System.Drawing.Color]::OrangeRed }
    return [System.Drawing.Color]::LightGray
}

# --- Form ---
$form            = New-Object System.Windows.Forms.Form
$form.Text       = "PyAppRelease - Python App Release Tool"
$form.ClientSize = New-Object System.Drawing.Size(660, 780)
$form.MinimumSize= New-Object System.Drawing.Size(680, 820)
$form.StartPosition = "CenterScreen"
$form.Font       = New-Object System.Drawing.Font("Segoe UI", 9)
$form.MaximizeBox = $false

$P = 12

# === PROJECT ===
$grpProj          = New-Object System.Windows.Forms.GroupBox
$grpProj.Text     = " Project "
$grpProj.Location = New-Object System.Drawing.Point($P, $P)
$grpProj.Size     = New-Object System.Drawing.Size(636, 110)
$grpProj.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblFolderLbl          = New-Object System.Windows.Forms.Label
    $lblFolderLbl.Text     = "Project Folder:"
    $lblFolderLbl.AutoSize = $true
    $lblFolderLbl.Location = New-Object System.Drawing.Point(8, 27)

    $txtFolder          = New-Object System.Windows.Forms.TextBox
    $txtFolder.Location = New-Object System.Drawing.Point(112, 24)
    $txtFolder.Size     = New-Object System.Drawing.Size(430, 23)
    $txtFolder.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnBrowse          = New-Object System.Windows.Forms.Button
    $btnBrowse.Text     = "Browse..."
    $btnBrowse.Location = New-Object System.Drawing.Point(550, 23)
    $btnBrowse.Size     = New-Object System.Drawing.Size(74, 25)
    $btnBrowse.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Select a project folder containing release.config.psd1"
    $lblStatus.Location  = New-Object System.Drawing.Point(112, 56)
    $lblStatus.Size      = New-Object System.Drawing.Size(512, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::Gray
    $lblStatus.Anchor    = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblCurVerLbl          = New-Object System.Windows.Forms.Label
    $lblCurVerLbl.Text     = "Current Version:"
    $lblCurVerLbl.AutoSize = $true
    $lblCurVerLbl.Location = New-Object System.Drawing.Point(8, 83)

    $lblCurVer          = New-Object System.Windows.Forms.Label
    $lblCurVer.Text     = "---"
    $lblCurVer.AutoSize = $true
    $lblCurVer.Location = New-Object System.Drawing.Point(112, 83)
    $lblCurVer.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

$grpProj.Controls.AddRange(@($lblFolderLbl, $txtFolder, $btnBrowse, $lblStatus, $lblCurVerLbl, $lblCurVer))

# === VERSION ===
$grpVer          = New-Object System.Windows.Forms.GroupBox
$grpVer.Text     = " New Version "
$grpVer.Location = New-Object System.Drawing.Point($P, 132)
$grpVer.Size     = New-Object System.Drawing.Size(636, 118)
$grpVer.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $rbPatch          = New-Object System.Windows.Forms.RadioButton
    $rbPatch.Text     = "Patch"
    $rbPatch.Checked  = $true
    $rbPatch.Location = New-Object System.Drawing.Point(8, 22)
    $rbPatch.Size     = New-Object System.Drawing.Size(240, 22)

    $rbMinor          = New-Object System.Windows.Forms.RadioButton
    $rbMinor.Text     = "Minor"
    $rbMinor.Location = New-Object System.Drawing.Point(8, 48)
    $rbMinor.Size     = New-Object System.Drawing.Size(240, 22)

    $rbMajor          = New-Object System.Windows.Forms.RadioButton
    $rbMajor.Text     = "Major"
    $rbMajor.Location = New-Object System.Drawing.Point(8, 74)
    $rbMajor.Size     = New-Object System.Drawing.Size(240, 22)

    $rbCustom          = New-Object System.Windows.Forms.RadioButton
    $rbCustom.Text     = "Custom:"
    $rbCustom.Location = New-Object System.Drawing.Point(260, 22)
    $rbCustom.Size     = New-Object System.Drawing.Size(75, 22)

    $txtCustomVer          = New-Object System.Windows.Forms.TextBox
    $txtCustomVer.Location = New-Object System.Drawing.Point(340, 20)
    $txtCustomVer.Size     = New-Object System.Drawing.Size(100, 23)
    $txtCustomVer.Enabled  = $false

    $lblPreview           = New-Object System.Windows.Forms.Label
    $lblPreview.Text      = "->  ---"
    $lblPreview.Location  = New-Object System.Drawing.Point(260, 52)
    $lblPreview.Size      = New-Object System.Drawing.Size(360, 52)
    $lblPreview.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 80)
    $lblPreview.Font      = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)

$grpVer.Controls.AddRange(@($rbPatch, $rbMinor, $rbMajor, $rbCustom, $txtCustomVer, $lblPreview))

# === SIGNING ===
$grpSign          = New-Object System.Windows.Forms.GroupBox
$grpSign.Text     = " Code Signing (optional) "
$grpSign.Location = New-Object System.Drawing.Point($P, 260)
$grpSign.Size     = New-Object System.Drawing.Size(636, 132)
$grpSign.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $rbSkipSign          = New-Object System.Windows.Forms.RadioButton
    $rbSkipSign.Text     = "Skip signing"
    $rbSkipSign.Checked  = $true
    $rbSkipSign.Location = New-Object System.Drawing.Point(8, 22)
    $rbSkipSign.Size     = New-Object System.Drawing.Size(120, 22)

    $rbThumb          = New-Object System.Windows.Forms.RadioButton
    $rbThumb.Text     = "Certificate Store (thumbprint):"
    $rbThumb.Location = New-Object System.Drawing.Point(8, 50)
    $rbThumb.Size     = New-Object System.Drawing.Size(210, 22)

    $txtThumb          = New-Object System.Windows.Forms.TextBox
    $txtThumb.Location = New-Object System.Drawing.Point(222, 48)
    $txtThumb.Size     = New-Object System.Drawing.Size(402, 23)
    $txtThumb.Enabled  = $false
    $txtThumb.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $rbPfx          = New-Object System.Windows.Forms.RadioButton
    $rbPfx.Text     = "PFX File:"
    $rbPfx.Location = New-Object System.Drawing.Point(8, 80)
    $rbPfx.Size     = New-Object System.Drawing.Size(80, 22)

    $txtPfxPath          = New-Object System.Windows.Forms.TextBox
    $txtPfxPath.Location = New-Object System.Drawing.Point(92, 78)
    $txtPfxPath.Size     = New-Object System.Drawing.Size(350, 23)
    $txtPfxPath.Enabled  = $false
    $txtPfxPath.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $btnPfxBrowse          = New-Object System.Windows.Forms.Button
    $btnPfxBrowse.Text     = "Browse..."
    $btnPfxBrowse.Location = New-Object System.Drawing.Point(448, 77)
    $btnPfxBrowse.Size     = New-Object System.Drawing.Size(74, 25)
    $btnPfxBrowse.Enabled  = $false
    $btnPfxBrowse.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblPwd          = New-Object System.Windows.Forms.Label
    $lblPwd.Text     = "Password:"
    $lblPwd.AutoSize = $true
    $lblPwd.Location = New-Object System.Drawing.Point(92, 108)

    $txtPwd              = New-Object System.Windows.Forms.TextBox
    $txtPwd.Location     = New-Object System.Drawing.Point(162, 106)
    $txtPwd.Size         = New-Object System.Drawing.Size(200, 23)
    $txtPwd.PasswordChar = '*'
    $txtPwd.Enabled      = $false

$grpSign.Controls.AddRange(@($rbSkipSign, $rbThumb, $txtThumb, $rbPfx, $txtPfxPath, $btnPfxBrowse, $lblPwd, $txtPwd))

# === OPTIONS ===
$grpOpts          = New-Object System.Windows.Forms.GroupBox
$grpOpts.Text     = " Options "
$grpOpts.Location = New-Object System.Drawing.Point($P, 402)
$grpOpts.Size     = New-Object System.Drawing.Size(636, 55)
$grpOpts.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $chkGitTag          = New-Object System.Windows.Forms.CheckBox
    $chkGitTag.Text     = "Create git tag"
    $chkGitTag.Checked  = $true
    $chkGitTag.Location = New-Object System.Drawing.Point(8, 22)
    $chkGitTag.Size     = New-Object System.Drawing.Size(145, 22)

    $chkGitPush          = New-Object System.Windows.Forms.CheckBox
    $chkGitPush.Text     = "Push to remote"
    $chkGitPush.Checked  = $true
    $chkGitPush.Location = New-Object System.Drawing.Point(160, 22)
    $chkGitPush.Size     = New-Object System.Drawing.Size(145, 22)

    $chkDryRun          = New-Object System.Windows.Forms.CheckBox
    $chkDryRun.Text     = "Dry run (preview only - no actual changes)"
    $chkDryRun.Checked  = $false
    $chkDryRun.Location = New-Object System.Drawing.Point(312, 22)
    $chkDryRun.Size     = New-Object System.Drawing.Size(310, 22)

$grpOpts.Controls.AddRange(@($chkGitTag, $chkGitPush, $chkDryRun))

# === OUTPUT DIR ===
$lblOutLbl          = New-Object System.Windows.Forms.Label
$lblOutLbl.Text     = "Output Folder:"
$lblOutLbl.AutoSize = $true
$lblOutLbl.Location = New-Object System.Drawing.Point($P, 472)

$txtOutDir            = New-Object System.Windows.Forms.TextBox
$txtOutDir.Location   = New-Object System.Drawing.Point(112, 469)
$txtOutDir.Size       = New-Object System.Drawing.Size(432, 23)
$txtOutDir.ReadOnly   = $true
$txtOutDir.BackColor  = [System.Drawing.SystemColors]::Control
$txtOutDir.Anchor     = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

$btnOpenOut          = New-Object System.Windows.Forms.Button
$btnOpenOut.Text     = "Open Folder"
$btnOpenOut.Location = New-Object System.Drawing.Point(550, 468)
$btnOpenOut.Size     = New-Object System.Drawing.Size(74, 25)
$btnOpenOut.Enabled  = $false
$btnOpenOut.Anchor   = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right

# === LOG ===
$logBox            = New-Object System.Windows.Forms.RichTextBox
$logBox.Location   = New-Object System.Drawing.Point($P, 504)
$logBox.Size       = New-Object System.Drawing.Size(636, 212)
$logBox.ReadOnly   = $true
$logBox.BackColor  = [System.Drawing.Color]::FromArgb(18, 18, 18)
$logBox.ForeColor  = [System.Drawing.Color]::LightGray
$logBox.Font       = New-Object System.Drawing.Font("Consolas", 9)
$logBox.WordWrap   = $false
$logBox.ScrollBars = "Both"
$logBox.Anchor     = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

# === BUTTONS ===
$btnStart            = New-Object System.Windows.Forms.Button
$btnStart.Text       = "> Start Release"
$btnStart.Location   = New-Object System.Drawing.Point($P, 728)
$btnStart.Size       = New-Object System.Drawing.Size(160, 40)
$btnStart.Enabled    = $false
$btnStart.BackColor  = [System.Drawing.Color]::FromArgb(0, 120, 212)
$btnStart.ForeColor  = [System.Drawing.Color]::White
$btnStart.FlatStyle  = "Flat"
$btnStart.Font       = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Anchor     = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = "Close"
$btnClose.Location = New-Object System.Drawing.Point(180, 728)
$btnClose.Size     = New-Object System.Drawing.Size(80, 40)
$btnClose.Anchor   = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left

$form.Controls.AddRange(@(
    $grpProj, $grpVer, $grpSign, $grpOpts,
    $lblOutLbl, $txtOutDir, $btnOpenOut,
    $logBox,
    $btnStart, $btnClose
))

# --- state ---
$script:info      = @{ Valid=$false; Version=""; ConfigFound=$false; OutputDir="release"; AppName=""; VersionMissing=$false }
$script:runProc   = $null
$script:logFile   = $null     # temp file the child process writes to
$script:logReader = $null     # StreamReader that tails the log file
$script:tmpScript = $null     # temp .ps1 script for the child process

# --- UI timer ---
$uiTimer          = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 150
$uiTimer.Add_Tick({
    try {
        # Read new lines from the child process output file
        if ($script:logReader) {
            while ($true) {
                $line = $script:logReader.ReadLine()
                if ($null -eq $line) { break }
                $clean = $line -replace '\x1b\[[0-9;]*m', ''
                Append-Log $clean (Get-LineColor $clean)
            }
        }

        # Check if the child process has exited
        if ($script:runProc -and $script:runProc.HasExited) {
            # Drain any remaining output
            Start-Sleep -Milliseconds 200
            if ($script:logReader) {
                while ($true) {
                    $line = $script:logReader.ReadLine()
                    if ($null -eq $line) { break }
                    $clean = $line -replace '\x1b\[[0-9;]*m', ''
                    Append-Log $clean (Get-LineColor $clean)
                }
                $script:logReader.Close()
                $script:logReader = $null
            }

            $code = $script:runProc.ExitCode
            Write-TraceLog "WorkerExit" "Background release process exited with code $code"

            $script:runProc = $null
            $uiTimer.Stop()

            # Clean up temp files
            if ($script:logFile)   { Remove-Item $script:logFile   -ErrorAction SilentlyContinue }
            if ($script:tmpScript) { Remove-Item $script:tmpScript -ErrorAction SilentlyContinue }

            $btnStart.Enabled   = $script:info.Valid
            $btnStart.Text      = "> Start Release"
            $btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
            $script:info = Read-ProjectInfo $txtFolder.Text.Trim()
            Update-UI

            if ($code -eq 0) {
                Append-Log ""
                Append-Log ("=" * 55) ([System.Drawing.Color]::LightGreen)
                Append-Log "  Release completed successfully!" ([System.Drawing.Color]::LightGreen)
                Append-Log ("=" * 55) ([System.Drawing.Color]::LightGreen)
                $btnOpenOut.Enabled = (Test-Path $txtOutDir.Text -ErrorAction SilentlyContinue)
            } else {
                Append-Log ""
                Append-Log "  Release FAILED  (exit code: $code)" ([System.Drawing.Color]::OrangeRed)
            }
        }
    } catch {
        Write-TraceLog "TimerTick" "Error: $_"
        Write-ErrorLog "TimerTick" $_
    }
})

function Append-Log([string]$text, [System.Drawing.Color]$color = [System.Drawing.Color]::LightGray) {
    $logBox.SelectionStart  = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor  = $color
    $logBox.AppendText($text + "`n")
    $logBox.ScrollToCaret()
}

function Update-UI {
    try {
        $i = $script:info
        if ($i.ConfigFound) {
            $lblStatus.Text      = "[OK] release.config.psd1 found  ($($i.AppName))"
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $lblStatus.Text      = "[!] release.config.psd1 not found in this folder"
            $lblStatus.ForeColor = [System.Drawing.Color]::Crimson
        }
        if ($i.VersionMissing) {
            $lblCurVer.Text = "0.0.0 (VERSION file will be created on first release)"
        } elseif ($i.Version) {
            $lblCurVer.Text = $i.Version
        } else {
            $lblCurVer.Text = "VERSION file invalid"
        }
        $folder = $txtFolder.Text.Trim()
        $relOut = $i.OutputDir
        if ($folder -and $relOut -and -not [System.IO.Path]::IsPathRooted($relOut)) {
            $txtOutDir.Text = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($folder, $relOut))
        } elseif ($relOut) { $txtOutDir.Text = $relOut }
        Update-VersionPreview
        $btnStart.Enabled   = $i.Valid -and ($null -eq $script:runProc)
        $btnOpenOut.Enabled = ($txtOutDir.Text -ne "" -and (Test-Path $txtOutDir.Text -ErrorAction SilentlyContinue))
    } catch {
        Write-TraceLog "Update-UI" "Error: $_"
        Write-ErrorLog "Update-UI" $_
    }
}

function Update-VersionPreview {
    try {
        $ver = $script:info.Version
        if (-not $ver) { $lblPreview.Text = "->  ---"; return }
        $bump = if ($rbMajor.Checked) { "Major" } elseif ($rbMinor.Checked) { "Minor" } elseif ($rbCustom.Checked) { "Custom" } else { "Patch" }
        $new  = Get-BumpedVersion $ver $bump $txtCustomVer.Text.Trim()
        $lblPreview.Text = "->  $new"
        if ($ver -match '^\d+\.\d+\.\d+$') {
            $p = $ver -split '\.'; [int]$ma=$p[0]; [int]$mi=$p[1]; [int]$pa=$p[2]
            $rbPatch.Text = "Patch  ($ver  ->  $ma.$mi.$($pa+1))"
            $rbMinor.Text = "Minor  ($ver  ->  $ma.$($mi+1).0)"
            $rbMajor.Text = "Major  ($ver  ->  $($ma+1).0.0)"
        }
    } catch {
        Write-TraceLog "Update-VersionPreview" "Error: $_"
        Write-ErrorLog "Update-VersionPreview" $_
    }
}

# --- events ---
$btnBrowse.Add_Click({
    try {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = "Select project root folder (must contain release.config.psd1)"
        if ($txtFolder.Text -and (Test-Path $txtFolder.Text)) { $dlg.SelectedPath = $txtFolder.Text }
        if ($dlg.ShowDialog() -eq "OK") { $txtFolder.Text = $dlg.SelectedPath }
    } catch {
        Write-TraceLog "btnBrowse" "Error: $_"
        Write-ErrorLog "btnBrowse" $_
    }
})

$txtFolder.Add_TextChanged({
    try {
        $script:info = Read-ProjectInfo $txtFolder.Text.Trim()
        Update-UI
    } catch {
        Write-TraceLog "TextChanged" "Error: $_"
        Write-ErrorLog "TextChanged" $_
    }
})

foreach ($rb in @($rbPatch, $rbMinor, $rbMajor)) { $rb.Add_CheckedChanged({ Update-VersionPreview }) }

$rbCustom.Add_CheckedChanged({
    $txtCustomVer.Enabled = $rbCustom.Checked
    if ($rbCustom.Checked) { $txtCustomVer.Focus() }
    Update-VersionPreview
})
$txtCustomVer.Add_TextChanged({ Update-VersionPreview })

$rbSkipSign.Add_CheckedChanged({
    if (-not $rbSkipSign.Checked) { return }
    $txtThumb.Enabled=$false; $txtPfxPath.Enabled=$false; $btnPfxBrowse.Enabled=$false; $txtPwd.Enabled=$false
})
$rbThumb.Add_CheckedChanged({
    $txtThumb.Enabled=$rbThumb.Checked; $txtPfxPath.Enabled=$false; $btnPfxBrowse.Enabled=$false; $txtPwd.Enabled=$false
})
$rbPfx.Add_CheckedChanged({
    $txtThumb.Enabled=$false
    $txtPfxPath.Enabled=$rbPfx.Checked; $btnPfxBrowse.Enabled=$rbPfx.Checked; $txtPwd.Enabled=$rbPfx.Checked
})
$btnPfxBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "PFX Certificate|*.pfx|All files|*.*"
    if ($dlg.ShowDialog() -eq "OK") { $txtPfxPath.Text = $dlg.FileName }
})
$chkGitTag.Add_CheckedChanged({
    $chkGitPush.Enabled = $chkGitTag.Checked
    if (-not $chkGitTag.Checked) { $chkGitPush.Checked = $false }
})
$btnOpenOut.Add_Click({ if (Test-Path $txtOutDir.Text) { Start-Process explorer.exe $txtOutDir.Text } })
$btnClose.Add_Click({
    Write-TraceLog "UI" "Close button clicked."
    $form.Close()
})
$form.Add_Load({
    Write-TraceLog "Form" "Load event fired."
})
$form.Add_FormClosing({
    param($sender, $e)
    try {
        Write-TraceLog "FormClosing" ("Reason=" + $e.CloseReason + "; HasWorker=" + [bool]($script:runProc -and -not $script:runProc.HasExited))
        if ($script:runProc -and -not $script:runProc.HasExited) {
            $r = [System.Windows.Forms.MessageBox]::Show("Release is still running. Abort and close?", "Confirm", "YesNo", "Warning")
            if ($r -ne "Yes") { $e.Cancel=$true; return }
            try { $script:runProc.Kill() } catch {}
        }
        $uiTimer.Stop()
        if ($script:logReader)  { try { $script:logReader.Close() } catch {} }
        if ($script:logFile)    { Remove-Item $script:logFile   -ErrorAction SilentlyContinue }
        if ($script:tmpScript)  { Remove-Item $script:tmpScript -ErrorAction SilentlyContinue }
    } catch {
        Write-TraceLog "FormClosing" "Error: $_"
        Write-ErrorLog "FormClosing" $_
    }
})
$form.Add_FormClosed({
    Write-TraceLog "FormClosed" "Form closed event fired."
})

$btnStart.Add_Click({
  try {
    if ($script:runProc -and -not $script:runProc.HasExited) { return }
    if (-not $script:info.Valid) {
        [System.Windows.Forms.MessageBox]::Show("Project folder is not valid.`nEnsure it contains release.config.psd1 and VERSION.", "Invalid Project", "OK", "Warning") | Out-Null
        return
    }
    $bump = if ($rbMajor.Checked) {"Major"} elseif ($rbMinor.Checked) {"Minor"} elseif ($rbCustom.Checked) {"Custom"} else {"Patch"}
    if ($bump -eq "Custom" -and $txtCustomVer.Text.Trim() -notmatch '^\d+\.\d+\.\d+$') {
        [System.Windows.Forms.MessageBox]::Show("Custom version must be X.Y.Z format.", "Invalid Version", "OK", "Warning") | Out-Null
        return
    }
    $newVer = ($lblPreview.Text -replace '.*->\s*', '').Trim()
    if (-not $chkDryRun.Checked) {
        $msg = "Release  $($script:info.AppName)  v$newVer ?`n`nProject : $($txtFolder.Text.Trim())`nOutput  : $($txtOutDir.Text)"
        if ([System.Windows.Forms.MessageBox]::Show($msg, "Confirm Release", "YesNo", "Question") -ne "Yes") { return }
    }
    $modPath = Find-ModulePath
    if (-not $modPath) {
        $installScript = Join-Path $ScriptDir 'Install.ps1'
        [System.Windows.Forms.MessageBox]::Show("PyAppRelease module not found.`nRun: $installScript", "Module Missing", "OK", "Error") | Out-Null
        return
    }
    $folder = $txtFolder.Text.Trim() -replace "'", "''"
    $mod    = $modPath -replace "'", "''"

    # Signing credentials are passed via child-process environment variables
    # instead of writing secrets to the temp script file on disk.
    $signEnvVars = @{}
    if ($rbThumb.Checked -and $txtThumb.Text.Trim()) {
        $signEnvVars['PYAPP_SIGN_THUMBPRINT'] = $txtThumb.Text.Trim()
    } elseif ($rbPfx.Checked -and $txtPfxPath.Text.Trim()) {
        $signEnvVars['PYAPP_SIGN_PFX']      = $txtPfxPath.Text.Trim()
        $signEnvVars['PYAPP_SIGN_PASSWORD']  = $txtPwd.Text
    }

    $bumpArg = switch ($bump) {
        "Major"  { "-BumpMajor" }
        "Minor"  { "-BumpMinor" }
        "Custom" { "-VersionOverride '$($txtCustomVer.Text.Trim() -replace "'","''")'"}
        default  { "-BumpPatch" }
    }
    $flags = [System.Collections.Generic.List[string]]::new()
    if ($rbSkipSign.Checked)      { $flags.Add("-SkipSign")    }
    if (-not $chkGitTag.Checked)  { $flags.Add("-SkipGitTag")  }
    if (-not $chkGitPush.Checked) { $flags.Add("-SkipGitPush") }
    if ($chkDryRun.Checked)       { $flags.Add("-DryRun")      }
    $flagStr = $flags -join " "

    $script:tmpScript = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.ps1'
    $script:logFile   = [System.IO.Path]::GetTempFileName() -replace '\.tmp$', '.log'
    $logEsc = $script:logFile -replace "'", "''"
    @"
`$ErrorActionPreference = 'Continue'
`$_logPath = '$logEsc'
function _L(`$m) { [IO.File]::AppendAllText(`$_logPath, "`$m`r`n") }
try {
    Set-Location '$folder'
    Import-Module '$mod' -Force
    Invoke-PyAppRelease -ConfigFile 'release.config.psd1' $bumpArg $flagStr *>&1 |
        ForEach-Object { _L "`$_" }
} catch {
    _L "[ERR] `$_"
    _L (`$_ | Out-String)
    exit 1
}
"@ | Set-Content $script:tmpScript -Encoding UTF8

    # Ensure the log file exists so the reader can open it
    [IO.File]::WriteAllText($script:logFile, "")

    $logBox.Clear()
    Append-Log ("=" * 55) ([System.Drawing.Color]::DarkCyan)
    Append-Log "  Launching release pipeline..." ([System.Drawing.Color]::Cyan)
    Append-Log ("=" * 55) ([System.Drawing.Color]::DarkCyan)
    Append-Log ""

    $btnStart.Enabled   = $false
    $btnStart.Text      = "Running..."
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(200, 120, 0)

    # Open a non-locking reader to tail the output file from the timer
    $fs = New-Object System.IO.FileStream(
        $script:logFile,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    $script:logReader = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName        = "powershell.exe"
    $psi.Arguments       = "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$($script:tmpScript)`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    # Inject signing credentials into the child process environment only
    # so they never touch disk in the temp script file.
    foreach ($key in $signEnvVars.Keys) {
        $psi.EnvironmentVariables[$key] = $signEnvVars[$key]
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $proc.Start() | Out-Null
    $script:runProc = $proc
    $uiTimer.Start()
  } catch {
    Write-TraceLog "btnStart" "Error: $_"
    Write-ErrorLog "btnStart" $_
    [System.Windows.Forms.MessageBox]::Show("Failed to start release:`n$_", "Error", "OK", "Error") | Out-Null
    $btnStart.Enabled   = $script:info.Valid
    $btnStart.Text      = "> Start Release"
    $btnStart.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
  }
})

# --- launch ---
$initialDir = if ($ProjectDir -and (Test-Path $ProjectDir)) { $ProjectDir }
              else {
                  $cwd = (Get-Location).Path
                  if (Test-Path (Join-Path $cwd "release.config.psd1")) { $cwd } else { "" }
              }
if ($initialDir) { $txtFolder.Text = $initialDir }

[void]($form.Add_Shown({
    Write-TraceLog "Form" "Shown event fired."
    $form.Activate()
}))
Write-TraceLog "Startup" "InitialDir='$initialDir'"
Write-TraceLog "Startup" "Entering Application.Run(form)."
[System.Windows.Forms.Application]::Run($form)
Write-TraceLog "Startup" "Application.Run(form) returned."