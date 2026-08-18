@{
    # Project-wide PSScriptAnalyzer settings
    # Run with: Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Path ./skills -Recurse

    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Intentional: helper functions use plural nouns when returning collections
        # (e.g., Get-EnvironmentEndpoints, Get-PaginatedResults).
        'PSUseSingularNouns'

        # Intentional: internal helpers use domain-specific verbs (Exchange, Load, Setup)
        # that are not in the approved verb list. Public cmdlets use approved verbs.
        'PSUseApprovedVerbs'

        # Intentional: helper functions prepare request objects or state without
        # directly modifying system state. Adding ShouldProcess to every internal
        # helper would create excessive confirmation noise.
        'PSUseShouldProcessForStateChangingFunctions'

        # Intentional: $Profile is a documented public API parameter for config
        # profile selection. Renaming would be a breaking change.
        'PSAvoidAssignmentToAutomaticVariable'

        # Intentional: many parameters exist for future use or are consumed by
        # dynamic binding patterns that PSSA cannot trace.
        'PSReviewUnusedParameter'

        # False positive: file does not have a BOM; PSSA reports this incorrectly
        # for some UTF-8 encoded files.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
