# Settings resolution.
#
# Every v2 setting keeps its name and meaning, so existing variable groups
# keep working after an upgrade (v3.0.0 "keep working, warn" rule).
# Precedence for each setting: script parameter, then queue-time override
# (only for the five runtime parameters), then the variable-group /
# repository variable (environment variable), then the built-in default.

$script:Defaults = [ordered]@{
    BapApiRoot                 = 'https://api.bap.microsoft.com'
    BapApiVersion              = '2026-06-01'
    PowerPlatformScope         = 'https://api.powerplatform.com/.default'
    PpApiRoot                  = 'https://api.powerplatform.com'
    AppManagementApiVersion    = '2026-05-01-preview'
    FinOpsApiVersion           = '2024-10-01'
    DumpDiagnostics            = 'true'
    DumpSolutionCatalog        = 'false'
    RetryFailedInstalls        = 'true'
    WhatIf                     = 'false'
    EnvironmentFilter          = ''
    EnvironmentExclude         = ''
    AppExclude                 = ''
    UsePacFallback             = 'false'
    FinOpsApplyVersion         = 'false'
    FinOpsTargetVersion        = ''
    FinOpsEnvironmentFilter    = ''
    FinOpsDeploymentTypes      = 'UnifiedDeveloper,UnifiedSandbox,UnifiedProduction'
    FinOpsUpdateScope          = 'QualityUpdate'
    FinOpsBuildTrainMap        = ''
    FinOpsScheduleUrl          = 'https://raw.githubusercontent.com/MicrosoftDocs/Dynamics-365-Unified-Operations-public/main/articles/fin-ops-core/dev-itpro/get-started/quality-updates-schedule.md'
    # New in v3.0.0
    ProductionRing             = 'true'
    ProductionEnvironmentTypes = 'Production'
    ProductionEnvironments     = ''
    ProductionSoakDays         = '0'
    WaitForInstallsMinutes     = '30'
    FailOnIssues               = 'false'
    AuthMode                   = 'Auto'
    ServiceConnectionId        = ''
}

$script:FinOpsUpdateScopeValues = @('QualityUpdate', 'VersionUpdate', 'Any')
$script:AuthModeValues          = @('Auto', 'ClientSecret', 'Federated')

# Settings that also have a queue-time runtime parameter in the pipelines.
$script:OverridableSettings = @('WhatIf', 'UsePacFallback', 'FinOpsApplyVersion', 'FinOpsUpdateScope', 'FinOpsTargetVersion')

# Retired in v2.3.0. Still detected so the log can say so.
$script:RetiredSettings = @('UpdateFinOpsVersion', 'FinOpsInventory')

function Test-Unset {
    # Blank, an unexpanded pipeline macro ($(name) from an undefined variable)
    # or a placeholder word all mean "not set".
    param([AllowEmptyString()] [AllowNull()] [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $true }
    if ($Value -match '^\s*\$\(.*\)\s*$') { return $true }
    if ($Value -match '^\s*\$\{\{.*\}\}\s*$') { return $true }
    if ($Value -ieq '(empty)' -or $Value -ieq '(none)' -or $Value -ieq '(all)') { return $true }
    return $false
}

function Get-EnvValue {
    param([string] $Name)
    return [Environment]::GetEnvironmentVariable($Name)
}

function Resolve-SettingValue {
    param([string] $Name, [hashtable] $Bound)
    if ($Bound.ContainsKey($Name) -and -not (Test-Unset ([string]$Bound[$Name]))) { return [string]$Bound[$Name] }
    if ($script:OverridableSettings -contains $Name) {
        $ov = Get-EnvValue "${Name}Override"
        if ($Name -eq 'UsePacFallback' -and (Test-Unset $ov)) { $ov = Get-EnvValue 'UsePacFallbackOverride' }
        if (-not (Test-Unset $ov)) { return $ov.Trim() }
    }
    $lv = Get-EnvValue $Name
    if (-not (Test-Unset $lv)) { return $lv.Trim() }
    return [string]$script:Defaults[$Name]
}

function Get-RunSettings {
    <#
    .SYNOPSIS
        Builds the effective settings object from parameters and environment.
    #>
    param([hashtable] $Bound = @{})

    $raw = [ordered]@{}
    foreach ($k in $script:Defaults.Keys) { $raw[$k] = Resolve-SettingValue -Name $k -Bound $Bound }

    $tenant = [string]$Bound['TenantId']
    $authority = Resolve-SettingValue -Name 'Authority' -Bound $Bound
    if (Test-Unset $authority) { $authority = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" }

    $warnings = @()

    # finOpsUpdateScope: unknown values fall back to the default, with a warning.
    $scope = $script:Defaults.FinOpsUpdateScope
    $match = $script:FinOpsUpdateScopeValues | Where-Object { $_ -ieq $raw.FinOpsUpdateScope } | Select-Object -First 1
    if ($match) { $scope = $match }
    else { $warnings += "finOpsUpdateScope value '$($raw.FinOpsUpdateScope)' is not recognised. Valid values: $(Join-Names $script:FinOpsUpdateScopeValues). Using $scope." }

    $authMode = 'Auto'
    $am = $script:AuthModeValues | Where-Object { $_ -ieq $raw.AuthMode } | Select-Object -First 1
    if ($am) { $authMode = $am } else { $warnings += "authMode value '$($raw.AuthMode)' is not recognised. Valid values: $(Join-Names $script:AuthModeValues). Using Auto." }

    $soak = 0
    if (-not [int]::TryParse($raw.ProductionSoakDays, [ref]$soak) -or $soak -lt 0) { $warnings += "productionSoakDays '$($raw.ProductionSoakDays)' is not a whole number of days. Using 0."; $soak = 0 }
    $wait = 30
    if (-not [int]::TryParse($raw.WaitForInstallsMinutes, [ref]$wait) -or $wait -lt 0) { $warnings += "waitForInstallsMinutes '$($raw.WaitForInstallsMinutes)' is not a whole number of minutes. Using 30."; $wait = 30 }

    $retired = @()
    foreach ($r in $script:RetiredSettings) { if (-not (Test-Unset (Get-EnvValue $r))) { $retired += $r } }
    if ((Get-Count $retired) -gt 0) { $warnings += "These variables no longer exist and are ignored: $(Join-Names $retired). Remove them." }

    return [pscustomobject]@{
        ClientId                   = [string]$Bound['ClientId']
        ClientSecret               = [string]$Bound['ClientSecret']
        TenantId                   = $tenant
        Authority                  = $authority
        BapApiRoot                 = $raw.BapApiRoot.TrimEnd('/')
        BapScope                   = "$($raw.BapApiRoot.TrimEnd('/'))/.default"
        BapApiVersion              = $raw.BapApiVersion
        PowerPlatformScope         = $raw.PowerPlatformScope
        PpApiRoot                  = $raw.PpApiRoot.TrimEnd('/')
        AppManagementApiVersion    = $raw.AppManagementApiVersion
        FinOpsApiVersion           = $raw.FinOpsApiVersion
        DumpDiagnostics            = ConvertTo-Bool $raw.DumpDiagnostics
        DumpSolutionCatalog        = ConvertTo-Bool $raw.DumpSolutionCatalog
        RetryFailedInstalls        = ConvertTo-Bool $raw.RetryFailedInstalls
        PlanOnly                   = ConvertTo-Bool $raw.WhatIf
        UsePacFallback             = ConvertTo-Bool $raw.UsePacFallback
        EnvironmentFilter          = @(Split-List $raw.EnvironmentFilter)
        EnvironmentExclude         = @(Split-List $raw.EnvironmentExclude)
        AppExclude                 = @(Split-List $raw.AppExclude)
        FinOpsApplyVersion         = ConvertTo-Bool $raw.FinOpsApplyVersion
        FinOpsTargetVersion        = $raw.FinOpsTargetVersion
        FinOpsEnvironmentFilter    = @(Split-List $raw.FinOpsEnvironmentFilter)
        FinOpsDeploymentTypes      = @(Split-List $raw.FinOpsDeploymentTypes)
        FinOpsUpdateScope          = $scope
        FinOpsBuildTrainMap        = $raw.FinOpsBuildTrainMap
        FinOpsScheduleUrl          = $raw.FinOpsScheduleUrl
        ProductionRing             = ConvertTo-Bool $raw.ProductionRing
        ProductionEnvironmentTypes = @(Split-List $raw.ProductionEnvironmentTypes)
        ProductionEnvironments     = @(Split-List $raw.ProductionEnvironments)
        ProductionSoakDays         = $soak
        WaitForInstallsMinutes     = $wait
        FailOnIssues               = ConvertTo-Bool $raw.FailOnIssues
        AuthMode                   = $authMode
        ServiceConnectionId        = $raw.ServiceConnectionId
        Raw                        = $raw
        Warnings                   = $warnings
    }
}

function Write-EffectiveSettings {
    param($Settings, [string] $Version, [string] $Mode, [string] $Ring)
    Write-Section "d365-tenant-app-updater $Version"
    $rows = [ordered]@{
        'Host'                       = (Get-HostKind)
        'Mode'                       = $Mode
        'Ring applied'               = $Ring
        'WhatIf (plan only)'         = $Settings.PlanOnly
        'AuthMode'                   = $Settings.AuthMode
        'EnvironmentFilter'          = (Format-Scope -Raw $Settings.Raw.EnvironmentFilter -EmptyLabel '(all)')
        'EnvironmentExclude'         = (Format-Scope -Raw $Settings.Raw.EnvironmentExclude -EmptyLabel '(none)')
        'AppExclude'                 = (Format-Scope -Raw $Settings.Raw.AppExclude -EmptyLabel '(none)')
        'RetryFailedInstalls'        = $Settings.RetryFailedInstalls
        'UsePacFallback'             = $Settings.UsePacFallback
        'ProductionRing'             = $Settings.ProductionRing
        'ProductionEnvironmentTypes' = (Join-Names $Settings.ProductionEnvironmentTypes)
        'ProductionEnvironments'     = (Format-Scope -Raw $Settings.Raw.ProductionEnvironments -EmptyLabel '(none)')
        'ProductionSoakDays'         = $Settings.ProductionSoakDays
        'WaitForInstallsMinutes'     = $Settings.WaitForInstallsMinutes
        'FinOpsApplyVersion'         = $Settings.FinOpsApplyVersion
        'FinOpsUpdateScope'          = $Settings.FinOpsUpdateScope
        'FinOpsTargetVersion'        = $(if ($Settings.FinOpsTargetVersion) { $Settings.FinOpsTargetVersion } else { '(highest matching scope)' })
        'FinOpsEnvironmentFilter'    = (Format-Scope -Raw $Settings.Raw.FinOpsEnvironmentFilter -EmptyLabel '(all detected F&O environments)')
        'FinOpsDeploymentTypes'      = (Join-Names $Settings.FinOpsDeploymentTypes)
        'F&O release schedule'       = $(if ($Settings.FinOpsScheduleUrl -ieq 'none' -or $Settings.FinOpsScheduleUrl -ieq 'off') { 'disabled (built-in map only)' } else { 'downloaded at the start of the F&O phase' })
        'AppManagementApiVersion'    = $Settings.AppManagementApiVersion
        'FinOpsApiVersion'           = $Settings.FinOpsApiVersion
    }
    foreach ($k in $rows.Keys) { Write-Line ("  {0,-27}: {1}" -f $k, $rows[$k]) }
    if ($Settings.Raw.FinOpsBuildTrainMap) { Write-Line ("  {0,-27}: {1}" -f 'FinOpsBuildTrainMap', "$($Settings.Raw.FinOpsBuildTrainMap)  (override)") }
    foreach ($w in $Settings.Warnings) { Write-RunWarning $w }
}
