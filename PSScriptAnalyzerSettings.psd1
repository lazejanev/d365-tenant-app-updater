# PSScriptAnalyzer settings used by CI (.github/workflows/ci.yml).
# CI fails on Error severity; warnings are shown in the log.
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Pipeline logs are the product's output: Write-Host is intentional.
        'PSAvoidUsingWriteHost',
        # Internal helpers, not user-facing cmdlets.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        'PSUseApprovedVerbs',
        # The client secret arrives as a pipeline variable (string) by design.
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        # Tests use globals to share the fake tenant with mocks.
        'PSAvoidGlobalVars',
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
