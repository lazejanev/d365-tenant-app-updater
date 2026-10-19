<#
.SYNOPSIS
    Keeps Dynamics 365 first-party (Dataverse) apps and Finance and
    Operations versions current across every environment of a tenant.

.DESCRIPTION
    Thin entry point for Azure DevOps, GitHub Actions and local runs. All
    logic lives in the D365TenantAppUpdater module (src/).

    Collect -> plan -> apply -> (optional wait, waitForInstallsMinutes > 0) -> report:
      Phase 1  Dynamics 365 apps. Only apps already installed in an
               environment are updated, and only to a strictly newer version.
      Phase 2  Finance and Operations. Inventory always; version apply only
               when finOpsApplyVersion = true, per finOpsUpdateScope, never to
               a lower release train. The live build decides the train
               (Microsoft's PQU schedule, downloaded every run); the Anchor
               Solution is never used.
      Rings    With productionRing = true (default) a production environment
               only takes a version a non-production environment already runs.

    -Mode PlanAndApply  (default) plan and apply in one run, as in v2.
    -Mode Plan          write plan.json, summary.md and report.json only.
    -Mode Apply         apply plan.json (-PlanFile) for -Ring, re-checking
                        every action against the live tenant first.

    Every setting can be passed as a parameter or as an environment variable
    with the same name (variable group / repository variables). Parameters win.

    Requires PowerShell 7.2 or later.

.NOTES
    Version: see src/D365TenantAppUpdater/D365TenantAppUpdater.psd1
    Docs   : docs/ (setup-azure-devops.md, setup-github.md, parameters.md)
    Repo   : https://github.com/lazejanev/d365-tenant-app-updater
#>
#Requires -Version 7.2

[CmdletBinding()]
param(
    [string] $ClientId     = '',
    [string] $ClientSecret = '',
    [string] $TenantId     = '',

    [ValidateSet('PlanAndApply', 'Plan', 'Apply')] [string] $Mode = 'PlanAndApply',
    [ValidateSet('All', 'NonProduction', 'Production')] [string] $Ring = 'All',
    [string] $PlanFile        = '',
    [string] $OutputDirectory = '',

    [string] $Authority               = '',
    [string] $BapApiRoot              = '',
    [string] $BapApiVersion           = '',
    [string] $PowerPlatformScope      = '',
    [string] $PpApiRoot               = '',
    [string] $AppManagementApiVersion = '',
    [string] $FinOpsApiVersion        = '',

    [string] $DumpDiagnostics     = '',
    [string] $DumpSolutionCatalog = '',
    [string] $RetryFailedInstalls = '',
    [string] $WhatIf              = '',
    [string] $EnvironmentFilter   = '',
    [string] $EnvironmentExclude  = '',
    [string] $AppExclude          = '',
    [string] $UsePacFallback      = '',

    [string] $FinOpsApplyVersion      = '',
    [string] $FinOpsTargetVersion     = '',
    [string] $FinOpsEnvironmentFilter = '',
    [string] $FinOpsDeploymentTypes   = '',
    [string] $FinOpsUpdateScope       = '',
    [string] $FinOpsBuildTrainMap     = '',
    [string] $FinOpsScheduleUrl       = '',

    # New in v3.0.0
    [string] $ProductionRing             = '',
    [string] $ProductionEnvironmentTypes = '',
    [string] $ProductionEnvironments     = '',
    [string] $ProductionSoakDays         = '',
    [string] $WaitForInstallsMinutes     = '',
    [string] $FailOnIssues               = '',
    [string] $AuthMode                   = '',
    [string] $ServiceConnectionId        = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$moduleManifest = Join-Path $PSScriptRoot '../src/D365TenantAppUpdater/D365TenantAppUpdater.psd1'
Import-Module $moduleManifest -Force

$runParams = @('ClientId', 'ClientSecret', 'TenantId', 'Mode', 'Ring', 'PlanFile', 'OutputDirectory')
$settings = @{}
foreach ($k in $PSBoundParameters.Keys) {
    if ($runParams -notcontains $k) { $settings[$k] = [string]$PSBoundParameters[$k] }
}

$exitCode = Invoke-D365TenantAppUpdate -ClientId $ClientId -ClientSecret $ClientSecret -TenantId $TenantId `
    -Mode $Mode -Ring $Ring -PlanFile $PlanFile -OutputDirectory $OutputDirectory -Setting $settings
exit $exitCode
