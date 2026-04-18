# PyAppRelease.psd1 — Module manifest
@{
    ModuleVersion     = '1.0.0'
    GUID              = 'b3e2c4d1-5f6a-4b7c-8d9e-0a1b2c3d4e5f'
    Author            = 'chen2023yi'
    CompanyName       = 'chen2023yi'
    Copyright         = '(C) 2026 chen2023yi'
    Description       = 'Reusable Python / PyInstaller / Inno Setup release pipeline for Windows desktop apps.'
    PowerShellVersion = '5.1'
    RootModule        = 'PyAppRelease.psm1'
    FunctionsToExport = @('Invoke-PyAppRelease', 'New-PyAppReleaseConfig', 'Start-PyAppReleaseGUI')
    PrivateData       = @{
        PSData = @{
            Tags       = @('PyInstaller', 'InnoSetup', 'Release', 'Python', 'Windows', 'Packaging')
            ProjectUri = 'https://github.com/chen2023yi/PyAppRelease'
        }
    }
}
