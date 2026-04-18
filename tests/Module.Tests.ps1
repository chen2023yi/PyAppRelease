Describe 'PyAppRelease module' {
    It 'imports the module without error' {
        Import-Module (Join-Path $PSScriptRoot '..\PyAppRelease.psm1') -Force -ErrorAction Stop
        $cmds = Get-Command -Module PyAppRelease -ErrorAction SilentlyContinue
        $cmds | Should -Not -BeNullOrEmpty
    }

    It 'has Invoke-PyAppRelease function exported' {
        (Get-Command -Name Invoke-PyAppRelease -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
    }
}
