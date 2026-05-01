@{
    AppName        = "PyAppRelease"
    DisplayName    = "PyAppRelease"
    Description    = "PyAppRelease"
    Company        = ""

    EntryScript    = "main.py"
    VenvPython     = ".venv\Scripts\python.exe"

    Windowed       = $true
    OneFile        = $false
    CollectAll     = @()
    HiddenImports  = @()
    ExtraArgs      = @()
    Icon           = ""

    OutputDir      = "release"
    GitRemote      = "origin"
    TagPrefix      = "v"
}
