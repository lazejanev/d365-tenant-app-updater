@{
    # The single source of the version number. The run log and the report
    # read it from here, and the release workflow checks the tag against it.
    ModuleVersion     = '3.0.0'
    GUID              = '6b2f3d1e-8a4c-4e57-9a0d-2c7e5b9f4a13'
    RootModule        = 'D365TenantAppUpdater.psm1'
    Author            = 'Laze Janev'
    CompanyName       = 'Commerce Code'
    Copyright         = '(c) Laze Janev. MIT License.'
    Description       = 'Updates Dynamics 365 first-party apps and Finance and Operations versions across a Power Platform tenant, from Azure DevOps or GitHub Actions.'
    PowerShellVersion = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport = @('Invoke-D365TenantAppUpdate', 'Get-D365TenantAppUpdaterVersion')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Dynamics365', 'PowerPlatform', 'Dataverse', 'FinanceAndOperations', 'AzureDevOps', 'GitHubActions')
            LicenseUri = 'https://github.com/lazejanev/d365-tenant-app-updater/blob/main/LICENSE'
            ProjectUri = 'https://github.com/lazejanev/d365-tenant-app-updater'
        }
    }
}
