@{
    # PSScriptAnalyzer settings for PyAppRelease
    # Exclude the BOM rule (often irrelevant for repo files) and tune severities.
    ExcludeRule = @('PSUseBOMForUnicodeEncodedFile')

    Rules = @{
        'PSAvoidUsingWriteHost' = @{ Enable = $false }
        'PSUseDeclaredVarsMoreThanAssignments' = @{ Enable = $true; Severity = 'Warning' }
        'PSAvoidUsingPlainTextForPassword' = @{ Enable = $true; Severity = 'Error' }
    }
}
