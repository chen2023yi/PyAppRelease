@{
    # PSScriptAnalyzer settings for PyAppRelease
    # Exclude the BOM rule (often irrelevant for repo files) and tune severities.
    ExcludeRules = @('PSUseBOMForUnicodeEncodedFile', 'PSAvoidUsingWriteHost')

    Rules = @{
        'PSUseDeclaredVarsMoreThanAssignments' = @{ Enabled = $true; Severity = 'Warning' }
        'PSAvoidUsingPlainTextForPassword' = @{ Enabled = $true; Severity = 'Error' }
    }
}
