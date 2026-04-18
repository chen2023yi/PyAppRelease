Describe 'PyAppRelease module' {
    It 'imports the module without error' {
        Import-Module (Join-Path $PSScriptRoot '..\PyAppRelease.psm1') -Force -ErrorAction Stop
        $cmds = Get-Command -Module PyAppRelease -ErrorAction SilentlyContinue
        if (-not (($cmds | Measure-Object).Count -gt 0)) { throw 'Expected module to export commands' }
    }

    It 'has Invoke-PyAppRelease function exported' {
        $count = ((Get-Command -Name Invoke-PyAppRelease -ErrorAction SilentlyContinue) | Measure-Object).Count
        if (-not ($count -gt 0)) { throw 'Invoke-PyAppRelease not exported' }
    }
}
