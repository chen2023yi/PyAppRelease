Describe 'PyAppRelease module' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '..\PyAppRelease.psm1') -Force -ErrorAction Stop
    }

    It 'imports the module without error' {
        $cmds = Get-Command -Module PyAppRelease -ErrorAction SilentlyContinue
        if (-not (($cmds | Measure-Object).Count -gt 0)) { throw 'Expected module to export commands' }
    }

    It 'has Invoke-PyAppRelease function exported' {
        $count = ((Get-Command -Name Invoke-PyAppRelease -ErrorAction SilentlyContinue) | Measure-Object).Count
        if (-not ($count -gt 0)) { throw 'Invoke-PyAppRelease not exported' }
    }

    It 'writes installed shortcut icon settings into the generated Inno script' {
        $iconPath = Join-Path $TestDrive 'app.ico'
        $issPath = Join-Path $TestDrive 'auto.iss'
        Set-Content -Path $iconPath -Value 'icon' -Encoding ASCII

        & (Get-Module PyAppRelease) {
            param($scriptPath, $shortcutIconPath)
            New-AutoInnoScript -Path $scriptPath -AppName 'SampleApp' -DisplayName 'Sample App' -Company '' -Version '1.2.3' -OneFile $false -Icon $shortcutIconPath
        } $issPath $iconPath

        $content = Get-Content -Path $issPath -Raw
        if (-not $content.Contains('Source: "{#IconPath}"; DestDir: "{app}"; DestName: "_pyapprelease_shortcut_{#AppVersion}.ico"; Flags: ignoreversion')) {
            throw 'Expected generated script to copy the selected icon into the install directory.'
        }
        if (-not $content.Contains('Name: "{group}\\{#AppName}"; Filename: "{app}\\{#AppName}.exe"; IconFilename: "{app}\_pyapprelease_shortcut_{#AppVersion}.ico"')) {
            throw 'Expected generated script to set the Start Menu shortcut icon.'
        }
        if (-not $content.Contains('Name: "{autodesktop}\\{#AppName}"; Filename: "{app}\\{#AppName}.exe"; IconFilename: "{app}\_pyapprelease_shortcut_{#AppVersion}.ico"; Tasks: desktopicon')) {
            throw 'Expected generated script to set the desktop shortcut icon.'
        }
        if (-not $content.Contains('Type: files; Name: "{app}\_pyapprelease_shortcut*.ico"')) {
            throw 'Expected generated script to clean old shortcut icon files during install and uninstall.'
        }
    }

    It 'uses the modern Git credential helper when manager-core is configured but unavailable' {
        & (Get-Module PyAppRelease) {
            $script:warningMessages = @()

            function script:git {
                param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Arguments)

                $argList = @($Arguments | ForEach-Object { [string]$_ })
                if ($argList.Count -ge 4 -and $argList[2] -eq 'config' -and $argList[3] -eq '--get-all') {
                    $global:LASTEXITCODE = 0
                    'manager-core'
                    return
                }

                throw "Unexpected git invocation: $($argList -join ' ')"
            }

            function script:Get-Command {
                param(
                    [Parameter(Position = 0)]
                    [string]$Name
                )

                if ($Name -eq 'git-credential-manager-core') {
                    return $null
                }

                if ($Name -eq 'git-credential-manager') {
                    return [pscustomobject]@{ Name = $Name; Source = 'git-credential-manager.exe' }
                }

                Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
            }

            function script:Write-ReleaseWarn([string]$msg) {
                $script:warningMessages += $msg
            }

            $result = Get-GitCommandArgs -ProjectRoot 'C:\Repo' -RequireCredentialHelper

            if (@($result) -join ' ' -ne '-C C:\Repo -c credential.helper=manager') {
                throw "Expected temporary credential helper override, got: $(@($result) -join ' ')"
            }

            if (-not ($script:warningMessages | Where-Object { $_ -like '*credential.helper includes ''manager-core''*' })) {
                throw 'Expected compatibility warning when falling back to manager.'
            }
        }
    }
}
