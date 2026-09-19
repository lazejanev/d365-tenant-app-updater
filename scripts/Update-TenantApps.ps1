<#
.SYNOPSIS
    Updates all Dynamics 365 first-party (Dataverse) apps across every
    environment on a tenant, reports Finance and Operations inventory, and
    applies F&O application versions on eligible environments.

.DESCRIPTION
    Phase 1 (always runs)
      Discovers every Dataverse environment, reads available application
      packages, reads installed versions from Dataverse managed solutions,
      and installs updates where a strictly newer version exists.

    Phase 2 (opt-in, UpdateFinOpsVersion)
      a. INVENTORY - runs for EVERY environment where F&O is installed.
         Reports application version, platform version, deployment type,
         AOS counts, demo dataset and scheduled actions.
      b. VERSION UPDATE - only for eligible deployment types. LCS managed
         environments (LCSSandbox, LCSProduction) are deliberately excluded
         because their application updates are driven through Lifecycle
         Services, not the Power Platform API.

.NOTES
    v2.2.0
      - Every environment is probed individually. An earlier build stopped
        after the first RouteNotFound and assumed the rest would behave the
        same, which hid per deployment type differences. A 404 over REST
        costs about 25 ms, so probing all of them is effectively free.
      - Reporting is factual. The script states what the API returned
        (for example RouteNotFound) rather than asserting a cause such as
        regional rollout.
      - New variable FinOpsDeploymentTypes controls which deployment types
        are eligible for a version apply. Default excludes LCS managed
        environments. Inventory is still collected for them.

    Verified 2026-09-19 (westeurope, app-only token):
      GET /dynamics/environments/{id}/finopsproperties -> HTTP 200
      GET /dynamics/environments/{id}/finopsversions   -> HTTP 404 RouteNotFound
    So auth, environment id and api-version are correct.

    PowerShell variable names are case-insensitive, so every local here is
    prefixed (opt*, cfg*) and can never collide with a parameter name.

    Author : Laze Janev
    License: MIT
    Repo   : https://github.com/lazejanev/d365-tenant-app-updater
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecret,
    [Parameter(Mandatory = $true)] [string] $TenantId,

    [Parameter()] [string] $Authority               = '',
    [Parameter()] [string] $BapApiRoot              = '',
    [Parameter()] [string] $BapApiVersion           = '',
    [Parameter()] [string] $PowerPlatformScope      = '',
    [Parameter()] [string] $PpApiRoot               = '',
    [Parameter()] [string] $AppManagementApiVersion = '',
    [Parameter()] [string] $FinOpsApiVersion        = '',
    [Parameter()] [string] $PollIntervalSec         = '',
    [Parameter()] [string] $PollTimeoutMin          = '',

    [Parameter()] [string] $DumpDiagnostics     = '',
    [Parameter()] [string] $RetryFailedInstalls = '',
    [Parameter()] [string] $WhatIf              = '',
    [Parameter()] [string] $EnvironmentFilter   = '',
    [Parameter()] [string] $EnvironmentExclude  = '',
    [Parameter()] [string] $AppExclude          = '',
    [Parameter()] [string] $UsePacFallback      = '',

    [Parameter()] [string] $UpdateFinOpsVersion     = '',
    [Parameter()] [string] $FinOpsTargetVersion     = '',
    [Parameter()] [string] $FinOpsEnvironmentFilter = '',
    # Deployment types eligible for a version apply. LCS managed environments
    # are excluded by default because they are updated through Lifecycle
    # Services. Inventory is still reported for every F&O environment.
    [Parameter()] [string] $FinOpsDeploymentTypes   = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$Defaults = @{
    BapApiRoot              = 'https://api.bap.microsoft.com'
    BapApiVersion           = '2026-06-01'
    PowerPlatformScope      = 'https://api.powerplatform.com/.default'
    PpApiRoot               = 'https://api.powerplatform.com'
    AppManagementApiVersion = '2026-05-01-preview'
    FinOpsApiVersion        = '2024-10-01'
    PollIntervalSec         = '20'
    PollTimeoutMin          = '60'
    DumpDiagnostics         = 'true'
    RetryFailedInstalls     = 'true'
    WhatIf                  = 'false'
    EnvironmentFilter       = ''
    EnvironmentExclude      = ''
    AppExclude              = ''
    UsePacFallback          = 'false'
    UpdateFinOpsVersion     = 'false'
    FinOpsTargetVersion     = ''
    FinOpsEnvironmentFilter = ''
    FinOpsDeploymentTypes   = 'UnifiedDeveloper,UnifiedSandbox,UnifiedProduction'
}

function Get-OrDefault {
    param([AllowEmptyString()] [string] $Value, [AllowEmptyString()] [string] $Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    if ($Value -match '^\s*\$\(.*\)\s*$') { return $Default }
    if ($Value -ieq '(empty)' -or $Value -ieq '(none)' -or $Value -ieq '(all)') { return $Default }
    return $Value
}

function Resolve-Setting {
    param([AllowEmptyString()] [string] $ParamValue, [string] $EnvName, [AllowEmptyString()] [string] $Default)
    $v = $ParamValue
    if ((Get-OrDefault $v '__unset__') -eq '__unset__') { $v = [Environment]::GetEnvironmentVariable($EnvName) }
    return Get-OrDefault $v $Default
}

function Resolve-Overridable {
    param([AllowEmptyString()] [string] $ParamValue, [string] $OverrideEnvName, [string] $LibraryEnvName, [AllowEmptyString()] [string] $Default)
    if ((Get-OrDefault $ParamValue '__unset__') -ne '__unset__') { return $ParamValue }
    $ov = [Environment]::GetEnvironmentVariable($OverrideEnvName)
    if ((Get-OrDefault $ov '__unset__') -ne '__unset__') { return (Get-OrDefault $ov $Default) }
    $lv = [Environment]::GetEnvironmentVariable($LibraryEnvName)
    return (Get-OrDefault $lv $Default)
}

function Get-Count {
    param($Value)
    $n = 0
    if ($null -ne $Value) { foreach ($x in $Value) { $n++ } }
    return $n
}

function ConvertTo-Bool {
    param([AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return @('true','1','yes','y','on') -contains ($Text.Trim().ToLowerInvariant())
}

function Split-List {
    param([AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $out = @()
    foreach ($piece in $Text.Split(',')) {
        $t = $piece.Trim()
        if ($t -ne '') { $out += $t }
    }
    return $out
}

function Join-Names {
    param($Items)
    $parts = @()
    foreach ($i in $Items) { if ($null -ne $i) { $parts += [string]$i } }
    if ($parts.Count -eq 0) { return '' }
    return [string]::Join(', ', $parts)
}

function Format-Scope {
    param([AllowEmptyString()] [string] $Raw, [string] $EmptyLabel)
    $list = Split-List $Raw
    if ((Get-Count $list) -eq 0) { return $EmptyLabel }
    return (Join-Names $list)
}

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "===== $Text ====="
}

function Get-ErrorText {
    param($ErrorRecord)
    $parts = @()
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts += [string]$ErrorRecord.ErrorDetails.Message }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message)       { $parts += [string]$ErrorRecord.Exception.Message }
    if ($parts.Count -eq 0) { return [string]$ErrorRecord }
    return [string]::Join(' ', $parts)
}

$cfgAuthority  = Resolve-Setting $Authority               'Authority'               "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$cfgBapRoot    = Resolve-Setting $BapApiRoot              'BapApiRoot'              $Defaults.BapApiRoot
$cfgBapVersion = Resolve-Setting $BapApiVersion           'BapApiVersion'           $Defaults.BapApiVersion
$cfgPpScope    = Resolve-Setting $PowerPlatformScope      'PowerPlatformScope'      $Defaults.PowerPlatformScope
$cfgPpRoot     = Resolve-Setting $PpApiRoot               'PpApiRoot'               $Defaults.PpApiRoot
$cfgAppMgmtVer = Resolve-Setting $AppManagementApiVersion 'AppManagementApiVersion' $Defaults.AppManagementApiVersion
$cfgFinOpsVer  = Resolve-Setting $FinOpsApiVersion        'FinOpsApiVersion'        $Defaults.FinOpsApiVersion
$cfgPollSec    = [int](Resolve-Setting $PollIntervalSec   'PollIntervalSec'         $Defaults.PollIntervalSec)
$cfgPollMin    = [int](Resolve-Setting $PollTimeoutMin    'PollTimeoutMin'          $Defaults.PollTimeoutMin)

$optDumpDiag   = ConvertTo-Bool (Resolve-Setting     $DumpDiagnostics     'DumpDiagnostics'     $Defaults.DumpDiagnostics)
$optRetry      = ConvertTo-Bool (Resolve-Setting     $RetryFailedInstalls 'RetryFailedInstalls' $Defaults.RetryFailedInstalls)
$optPlanOnly   = ConvertTo-Bool (Resolve-Overridable $WhatIf         'WhatIfOverride'         'WhatIf'         $Defaults.WhatIf)
$optUsePac     = ConvertTo-Bool (Resolve-Overridable $UsePacFallback 'UsePacFallbackOverride' 'UsePacFallback' $Defaults.UsePacFallback)
$optEnvFilter  = Resolve-Setting $EnvironmentFilter  'EnvironmentFilter'  $Defaults.EnvironmentFilter
$optEnvExclude = Resolve-Setting $EnvironmentExclude 'EnvironmentExclude' $Defaults.EnvironmentExclude
$optAppExclude = Resolve-Setting $AppExclude         'AppExclude'         $Defaults.AppExclude

$optDoFinOps      = ConvertTo-Bool (Resolve-Overridable $UpdateFinOpsVersion 'UpdateFinOpsVersionOverride' 'UpdateFinOpsVersion' $Defaults.UpdateFinOpsVersion)
$optFinOpsTarget  = Resolve-Overridable $FinOpsTargetVersion 'FinOpsTargetVersionOverride' 'FinOpsTargetVersion' $Defaults.FinOpsTargetVersion
$optFinOpsEnvList = Resolve-Setting     $FinOpsEnvironmentFilter 'FinOpsEnvironmentFilter' $Defaults.FinOpsEnvironmentFilter
$optFinOpsDepTypes= Resolve-Setting     $FinOpsDeploymentTypes   'FinOpsDeploymentTypes'   $Defaults.FinOpsDeploymentTypes

$Config = [ordered]@{
    Authority               = $cfgAuthority
    BapApiRoot              = $cfgBapRoot.TrimEnd('/')
    BapScope                = "$($cfgBapRoot.TrimEnd('/'))/.default"
    BapApiVersion           = $cfgBapVersion
    PowerPlatformScope      = $cfgPpScope
    PpApiRoot               = $cfgPpRoot.TrimEnd('/')
    AppManagementApiVersion = $cfgAppMgmtVer
    FinOpsApiVersion        = $cfgFinOpsVer
    PollIntervalSec         = $cfgPollSec
    PollTimeoutMin          = $cfgPollMin
}

function Get-Token {
    param([string] $Scope)
    $body = @{ client_id = $ClientId; client_secret = $ClientSecret; grant_type = 'client_credentials'; scope = $Scope }
    $r = Invoke-RestMethod -Method POST -Uri $Config.Authority -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    if (-not $r.access_token) { throw "No access_token for scope '$Scope'." }
    return $r.access_token
}

# Status-aware call. Never throws on an HTTP error.
function Invoke-PpRest {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)] [string] $RequestUri,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [string] $Body = ''
    )
    $status = 0
    $text   = ''
    try {
        $p = @{ Method = $Method; Uri = $RequestUri; Headers = $Headers; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
        if ($Body -ne '') { $p['Body'] = $Body; $p['ContentType'] = 'application/json' }
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        if ($null -ne $r.Content) { $text = [string]$r.Content }
    }
    catch {
        $status = -1
        $text = (Get-ErrorText -ErrorRecord $_)
    }
    $json = $null
    if ($text -ne '') {
        $t = $text.Trim()
        $i = $t.IndexOfAny([char[]]@('{','['))
        if ($i -ge 0) { try { $json = $t.Substring($i) | ConvertFrom-Json } catch { $json = $null } }
    }
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json }
}

# Returns the API error code when present, for factual reporting.
function Get-ApiErrorCode {
    param($Response)
    if ($null -eq $Response) { return '' }
    if ($Response.Json -and $Response.Json.code)       { return [string]$Response.Json.code }
    if ($Response.Json -and $Response.Json.error -and $Response.Json.error.code) { return [string]$Response.Json.error.code }
    if ($Response.Text -and ([string]$Response.Text) -match 'does not match any known API routes') { return 'RouteNotFound' }
    return ''
}

function New-PpUrl {
    param([Parameter(Mandatory)] [string] $Path, [hashtable] $Query = @{})
    $b = [System.UriBuilder]::new("$($Config.PpApiRoot)$Path")
    $pairs = @()
    foreach ($k in $Query.Keys) {
        $pairs += "$([System.Uri]::EscapeDataString([string]$k))=$([System.Uri]::EscapeDataString([string]$Query[$k]))"
    }
    $pairs += "api-version=$([System.Uri]::EscapeDataString($Config.AppManagementApiVersion))"
    $b.Query = [string]::Join('&', $pairs)
    return $b.Uri.AbsoluteUri
}

function New-FinOpsUri {
    param([string] $EnvironmentId, [string] $Leaf)
    return ($Config.PpApiRoot + '/dynamics/environments/' + $EnvironmentId + '/' + $Leaf + '?api-version=' + $Config.FinOpsApiVersion)
}

function Get-SolutionVersionMap {
    param([string] $InstanceUrl, [string[]] $DumpHints = @())
    $base = $InstanceUrl.TrimEnd('/')
    $dvToken = Get-Token "$base/.default"
    $dvHeaders = @{
        Authorization      = "Bearer $dvToken"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
    if ((Get-Count $DumpHints) -gt 0) {
        Write-Host '##[group]DIAGNOSTIC: managed solutions matching hints (uniquename | friendlyname | version)'
    }
    $map = @{}
    $url = "$base/api/data/v9.2/solutions?`$select=uniquename,friendlyname,version&`$filter=ismanaged eq true&`$top=5000"
    while ($url) {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $dvHeaders -ErrorAction Stop
        foreach ($s in @($resp.value)) {
            if (-not $s.version) { continue }
            if ($s.uniquename) { $map[([string]$s.uniquename).ToLower()] = [string]$s.version }
            if ($s.friendlyname) {
                $fk = ([string]$s.friendlyname).ToLower()
                if (-not $map.ContainsKey($fk)) { $map[$fk] = [string]$s.version }
            }
            if ((Get-Count $DumpHints) -gt 0) {
                $hay = "$($s.uniquename) $($s.friendlyname)".ToLower()
                foreach ($h in $DumpHints) {
                    if ($hay -like "*$($h.ToLower())*") {
                        Write-Host (" [solution] {0} | {1} | {2}" -f $s.uniquename, $s.friendlyname, $s.version); break
                    }
                }
            }
        }
        $url = $resp.'@odata.nextLink'
    }
    if ((Get-Count $DumpHints) -gt 0) { Write-Host '##[endgroup]' }
    return $map
}

function Test-UpdateAvailable {
    param([string] $Available, [string] $Installed)
    $a = $null; $i = $null
    if ([System.Version]::TryParse($Available, [ref]$a) -and [System.Version]::TryParse($Installed, [ref]$i)) { return ($a -gt $i) }
    $as = $Available -split '\.'; $is = $Installed -split '\.'
    $n = [Math]::Max($as.Count, $is.Count)
    for ($k = 0; $k -lt $n; $k++) {
        $av = 0; $iv = 0
        [void][int]::TryParse(("$($as[$k])"), [ref]$av)
        [void][int]::TryParse(("$($is[$k])"), [ref]$iv)
        if ($av -ne $iv) { return ($av -gt $iv) }
    }
    return $false
}

function Resolve-InstalledVersion {
    param($Pkg, [hashtable] $Map, [hashtable] $Alias)
    $un = ([string]$Pkg.uniqueName).ToLower()
    if ($Alias -and $Alias.ContainsKey($un) -and $Map.ContainsKey($Alias[$un])) { return $Map[$Alias[$un]] }
    foreach ($key in @($Pkg.uniqueName, $Pkg.localizedName, $Pkg.applicationName)) {
        if ($key) {
            $k = ([string]$key).ToLower()
            if ($Map.ContainsKey($k)) { return $Map[$k] }
        }
    }
    return $null
}

function Test-AppExcluded {
    param($Pkg, $List)
    if ((Get-Count $List) -eq 0) { return $false }
    $keys = @()
    foreach ($k in @($Pkg.uniqueName, $Pkg.localizedName, $Pkg.applicationName, $Pkg.applicationId)) {
        if ($k) { $keys += ([string]$k).ToLower() }
    }
    foreach ($item in $List) {
        $needle = ([string]$item).Trim().ToLower()
        if ($needle -eq '') { continue }
        foreach ($k in $keys) {
            if ($k -eq $needle) { return $true }
            if ($needle.Contains('*')) { if ($k -like $needle) { return $true } }
            elseif ($k.Contains($needle)) { return $true }
        }
    }
    return $false
}

function Test-EnvInList {
    param($EnvObj, $List)
    if ((Get-Count $List) -eq 0) { return $false }
    foreach ($item in $List) {
        $needle = [string]$item
        if ($EnvObj.DisplayName -and ([string]$EnvObj.DisplayName) -ieq $needle) { return $true }
        if ($EnvObj.Id          -and ([string]$EnvObj.Id)          -ieq $needle) { return $true }
    }
    return $false
}

function Test-CustomInstallExperience {
    param([AllowEmptyString()] [string] $Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    $m = $Message.ToLowerInvariant()
    return ($m -match 'custom install experience') -or ($m -match 'single page application') -or ($m -match 'not supported by this api')
}

function Invoke-AppInstall {
    param($Pkg, [string] $EnvId, [hashtable] $Headers)
    $installUrl = New-PpUrl -Path "/appmanagement/environments/$EnvId/applicationPackages/$($Pkg.uniqueName)/install"
    $payload    = $Pkg | ConvertTo-Json -Depth 20 -Compress
    $resp = Invoke-RestMethod -Method POST -Uri $installUrl -Headers $Headers -ContentType 'application/json' -Body $payload -ErrorAction Stop
    if ($resp.lastOperation.operationId) { Write-Host "  Operation triggered: $($resp.lastOperation.operationId)"; return $true }
    Write-Host '  Install accepted (no operation id returned).'
    return $false
}

function Get-FinOpsMarker {
    param($Packages)
    $markers = @('msdyn_financeandoperationsprovisioningapp','financeandoperationsprovisioning','dynamics365financeandoperations')
    foreach ($p in @($Packages)) {
        $state = [string]$p.state
        if ($state -ne 'Installed' -and $state -ne 'InstallFailed') { continue }
        $un = ([string]$p.uniqueName).ToLower()
        $ln = ([string]$p.localizedName).ToLower()
        foreach ($m in $markers) {
            if ($un.Contains($m)) { return [string]$p.uniqueName }
        }
        if ($ln.Contains('finance and operations') -and -not $ln.Contains('package manager')) {
            return [string]$p.localizedName
        }
    }
    return $null
}

function ConvertTo-FinOpsVersionList {
    param($Json)
    if ($null -eq $Json) { return @() }
    $items = $Json
    foreach ($p in @('availableVersions','value','versions','items','data')) {
        if ($Json.$p) { $items = $Json.$p; break }
    }
    $versions = @()
    foreach ($i in @($items)) {
        $v = $null
        if ($i -is [string]) { $v = $i }
        else {
            foreach ($p in @('version','applicationVersion','name','value')) {
                if ($i.$p -and ([string]$i.$p) -match '^\d+(\.\d+)+') { $v = [string]$i.$p; break }
            }
        }
        if ($v -and ($versions -notcontains $v)) { $versions += $v }
    }
    return $versions
}

function Select-HighestVersion {
    param($Versions)
    $best = $null
    foreach ($v in $Versions) {
        $s = [string]$v
        if ($s -eq '') { continue }
        if ($null -eq $best) { $best = $s; continue }
        if (Test-UpdateAvailable -Available $s -Installed $best) { $best = $s }
    }
    return $best
}

$script:PacReady = $false

function Initialize-Pac {
    if ($script:PacReady) { return $true }
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) { Write-Warning 'Power Platform CLI (pac) is not installed on the agent.'; return $false }
    try {
        pac auth create --name d365updater --applicationId $ClientId --clientSecret $ClientSecret --tenant $TenantId | Out-Null
        $global:LASTEXITCODE = 0
        $script:PacReady = $true
        Write-Host '  PAC CLI authenticated with service principal.'
        return $true
    }
    catch { Write-Warning "  PAC auth create failed. $($_.Exception.Message)"; $global:LASTEXITCODE = 0; return $false }
}

function Invoke-PacInstall {
    param([string] $EnvironmentId, $Pkg)
    if (-not (Initialize-Pac)) { return $false }
    try {
        pac app-management install-application-package --environment $EnvironmentId --unique-name $Pkg.uniqueName
        if ($LASTEXITCODE -eq 0) { $global:LASTEXITCODE = 0; Write-Host "  [PAC] Install triggered for '$($Pkg.uniqueName)'."; return $true }
        pac application install --environment-id $EnvironmentId --application-name $Pkg.uniqueName
        if ($LASTEXITCODE -eq 0) { $global:LASTEXITCODE = 0; Write-Host "  [PAC] Install triggered (legacy) for '$($Pkg.uniqueName)'."; return $true }
        Write-Warning "  [PAC] Could not install '$($Pkg.uniqueName)'."
        $global:LASTEXITCODE = 0
        return $false
    }
    catch { Write-Warning "  [PAC] Install failed for '$($Pkg.uniqueName)'. $($_.Exception.Message)"; $global:LASTEXITCODE = 0; return $false }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
$filterList  = Split-List $optEnvFilter
$excludeList = Split-List $optEnvExclude
$appExcludeL = Split-List $optAppExclude
$foFilterL   = Split-List $optFinOpsEnvList
$foDepTypesL = Split-List $optFinOpsDepTypes
$appSolutionAlias = @{}

Write-Section 'Effective settings'
Write-Host ("  BapApiVersion           : " + $Config.BapApiVersion)
Write-Host ("  AppManagementApiVersion : " + $Config.AppManagementApiVersion)
Write-Host ("  DumpDiagnostics         : " + $optDumpDiag)
Write-Host ("  RetryFailedInstalls     : " + $optRetry)
Write-Host ("  WhatIf (plan only)      : " + $optPlanOnly)
Write-Host ("  UsePacFallback          : " + $optUsePac)
Write-Host ("  EnvironmentFilter       : " + (Format-Scope -Raw $optEnvFilter  -EmptyLabel '(all)'))
Write-Host ("  EnvironmentExclude      : " + (Format-Scope -Raw $optEnvExclude -EmptyLabel '(none)'))
Write-Host ("  AppExclude              : " + (Format-Scope -Raw $optAppExclude -EmptyLabel '(none)'))
Write-Host ("  UpdateFinOpsVersion     : " + $optDoFinOps)
if ($optDoFinOps) {
    $tgtLabel = '(latest available)'
    if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
    Write-Host ("  FinOpsApiVersion        : " + $Config.FinOpsApiVersion)
    Write-Host ("  FinOpsTargetVersion     : " + $tgtLabel)
    Write-Host ("  FinOpsEnvironmentFilter : " + (Format-Scope -Raw $optFinOpsEnvList -EmptyLabel '(all detected F&O environments)'))
    Write-Host ("  FinOpsDeploymentTypes   : " + (Format-Scope -Raw $optFinOpsDepTypes -EmptyLabel '(any)'))
    Write-Host '  Note: LCS managed environments are inventoried but not version-updated.'
}

Write-Section 'Authenticating'
$ppToken  = Get-Token $Config.PowerPlatformScope
$bapToken = Get-Token $Config.BapScope
Write-Host 'Acquired Power Platform and BAP tokens'

$ppHeaders  = @{ Authorization = "Bearer $ppToken";  Accept = 'application/json'; 'Content-Type' = 'application/json' }
$bapHeaders = @{ Authorization = "Bearer $bapToken"; Accept = 'application/json' }

Write-Section 'Listing environments'
$envUri = "$($Config.BapApiRoot)/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?`$expand=properties&api-version=$($Config.BapApiVersion)"
$envResp = Invoke-RestMethod -Method GET -Uri $envUri -Headers $bapHeaders -ErrorAction Stop

$environments = @()
foreach ($e in @($envResp.value)) {
    $instanceUrl = $e.properties.linkedEnvironmentMetadata.instanceUrl
    if (-not $instanceUrl) { continue }
    $dn = $e.name
    if ($e.properties.displayName) { $dn = $e.properties.displayName }
    $environments += [pscustomobject]@{ Id = $e.name; DisplayName = $dn; InstanceUrl = $instanceUrl }
}
Write-Host "Found $(Get-Count $environments) Dataverse environment(s)"

$scoped = @()
foreach ($envObj in $environments) {
    $inFilter  = ((Get-Count $filterList) -eq 0) -or (Test-EnvInList -EnvObj $envObj -List $filterList)
    $inExclude = Test-EnvInList -EnvObj $envObj -List $excludeList
    if ($inExclude) { Write-Host "  Skipping (excluded): $($envObj.DisplayName)"; continue }
    if (-not $inFilter) { continue }
    $scoped += $envObj
}
$environments = $scoped
Write-Host "Processing $(Get-Count $environments) environment(s) after filter and exclude."

$knownUpdateHints = @('Customer Service Analytics','Customer Service Intelligence','Agent Productivity','appprofilemanager','AppProfileManager')

$totalEnvironments = 0; $totalUpdates = 0; $totalRetries = 0; $totalOperations = 0
$totalUpToDate = 0; $totalNoMatch = 0; $totalFailed = 0; $totalManual = 0; $totalExcluded = 0
$solDumped = $false
$manualList     = @()
$finOpsDetected = @()

# ===================== PHASE 1: application updates =====================
foreach ($envObj in $environments) {
    $envId = $envObj.Id; $envName = $envObj.DisplayName; $instanceUrl = $envObj.InstanceUrl
    $totalEnvironments++

    Write-Host ''
    Write-Host '##[section]============================================================'
    Write-Host "##[section]ENVIRONMENT: $envName"
    Write-Host "##[section]ID: $envId"
    Write-Host '##[section]============================================================'

    try {
        $pkgUrl = New-PpUrl -Path "/appmanagement/environments/$envId/applicationPackages" -Query @{ appInstallState = 'All'; lcid = '1033' }
        $available = @((Invoke-RestMethod -Method GET -Uri $pkgUrl -Headers $ppHeaders -ErrorAction Stop).value)
    }
    catch { $totalFailed++; Write-Host "##[warning]Failed to list available packages for '$envName': $_"; continue }

    try {
        $hints = @()
        if ($optDumpDiag -and -not $solDumped) { $hints = @('crm','hub','sales','insight','productivity','globalization','quality','channel','customerservice','outlook') }
        $solMap = Get-SolutionVersionMap -InstanceUrl $instanceUrl -DumpHints $hints
        $solDumped = $true
    }
    catch {
        $totalFailed++
        Write-Host "##[warning]Failed to read Dataverse solution versions for '$envName': $_"
        Write-Host '##[warning]Skipping this environment (no installed data => nothing installed blindly).'
        continue
    }

    $foMarker = Get-FinOpsMarker -Packages $available
    if ($foMarker) {
        Write-Host "Finance and Operations solutions present (package: $foMarker)."
        $finOpsDetected += $envObj
    }

    $candidates = @()
    foreach ($p in $available) {
        if (-not $p.uniqueName) { continue }
        if ($p.state -eq 'Installed' -or ($optRetry -and $p.state -eq 'InstallFailed')) { $candidates += $p }
    }
    Write-Host "Installed apps evaluated: $(Get-Count $candidates)  (managed solutions read: $($solMap.Count))"

    if ($optDumpDiag) {
        Write-Host '##[group]DIAGNOSTIC: installed (solution) vs available for known apps'
        foreach ($c in $candidates) {
            $isKnown = $false
            foreach ($h in $knownUpdateHints) { if ("$($c.localizedName)" -like "*$h*" -or "$($c.uniqueName)" -like "*$h*") { $isKnown = $true } }
            if ($isKnown) {
                $iv = Resolve-InstalledVersion $c $solMap $appSolutionAlias
                $ivText = '<no matching solution>'
                if ($iv) { $ivText = $iv }
                Write-Host (" - {0} [{1}]  installed: {2}  available: {3}" -f $c.localizedName, $c.uniqueName, $ivText, $c.version)
            }
        }
        Write-Host '##[endgroup]'
    }

    $envUpdates = 0; $envRetries = 0; $envUpToDate = 0; $envNoMatch = 0; $envExcluded = 0; $envManual = 0; $noMatchNames = @()

    foreach ($pkg in $candidates) {
        $name = $pkg.uniqueName
        if ($pkg.localizedName) { $name = $pkg.localizedName }
        $avail = [string]$pkg.version

        if (Test-AppExcluded -Pkg $pkg -List $appExcludeL) {
            $envExcluded++; $totalExcluded++
            if ($optDumpDiag) { Write-Host "  Skipping (app excluded): $name" }
            continue
        }

        if ($pkg.state -eq 'InstallFailed') {
            $envRetries++; $totalRetries++
            Write-Host ''
            Write-Host "Retrying failed installation: $name  (target version: $avail)"
            if ($optPlanOnly) { Write-Host '  [WhatIf] would retry install.'; continue }
            try { if (Invoke-AppInstall -Pkg $pkg -EnvId $envId -Headers $ppHeaders) { $totalOperations++ } }
            catch {
                $errText = Get-ErrorText -ErrorRecord $_
                if (Test-CustomInstallExperience -Message $errText) {
                    $handled = $false
                    if ($optUsePac) { $handled = Invoke-PacInstall -EnvironmentId $envId -Pkg $pkg }
                    if (-not $handled) {
                        $envManual++; $totalManual++
                        $manualList += [pscustomobject]@{ Environment=$envName; App=$name; Installed=''; Available=$avail }
                        Write-Host "  Needs the Power Platform Admin Center install wizard."
                    }
                } else { $totalFailed++; Write-Host "##[warning]Failed to retry '$name': $errText" }
            }
            continue
        }

        $inst = Resolve-InstalledVersion $pkg $solMap $appSolutionAlias
        if (-not $inst) { $envNoMatch++; $totalNoMatch++; $noMatchNames += ("{0} [{1}] avail {2}" -f $name, $pkg.uniqueName, $avail); continue }
        if (-not (Test-UpdateAvailable -Available $avail -Installed $inst)) { $envUpToDate++; $totalUpToDate++; continue }

        $envUpdates++; $totalUpdates++
        Write-Host ''
        Write-Host "Update available: $name  installed: $inst  available: $avail"
        if ($optPlanOnly) { Write-Host "  [WhatIf] would update to $avail."; continue }
        try { if (Invoke-AppInstall -Pkg $pkg -EnvId $envId -Headers $ppHeaders) { $totalOperations++ } }
        catch {
            $errText = Get-ErrorText -ErrorRecord $_
            if (Test-CustomInstallExperience -Message $errText) {
                $handled = $false
                if ($optUsePac) { Write-Host "  Needs a custom install. Trying PAC CLI fallback..."; $handled = Invoke-PacInstall -EnvironmentId $envId -Pkg $pkg }
                if ($handled) { Write-Host "  Updated '$name' via PAC CLI." }
                else {
                    $envManual++; $totalManual++
                    $manualList += [pscustomobject]@{ Environment=$envName; App=$name; Installed=$inst; Available=$avail }
                    Write-Host "  Needs the Power Platform Admin Center install wizard (reported below, not a failure)."
                }
            } else { $totalFailed++; Write-Host "##[warning]Failed to update '$name': $errText" }
        }
    }

    if ($optDumpDiag -and (Get-Count $noMatchNames) -gt 0) {
        Write-Host '##[group]Apps with no matching managed solution (not evaluated for update)'
        foreach ($nm in $noMatchNames) { Write-Host " - $nm" }
        Write-Host '##[endgroup]'
    }
    Write-Host ''
    Write-Host "Environment summary -> updates: $envUpdates | failed-retries: $envRetries | up-to-date: $envUpToDate | no solution match: $envNoMatch | app-excluded: $envExcluded | manual: $envManual"
}

# ======= PHASE 2: Finance and Operations inventory and version update =======
#
# Every F&O environment is probed individually. Nothing is assumed from the
# result of another environment. Reporting states what the API returned.
#
# Version apply is attempted only for eligible deployment types. LCS managed
# environments are inventoried but never version-updated here, because their
# application updates are driven through Lifecycle Services.
$foInventory   = @()
$foChecked     = 0
$foApplied     = 0
$foFailed      = 0
$foPropsFailed = 0
$foNotEligible = 0
$foNoVersions  = 0

if ($optDoFinOps) {
    try {
        Write-Host ''
        Write-Host '##[section]============================================================'
        Write-Host '##[section]FINANCE AND OPERATIONS'
        Write-Host '##[section]============================================================'

        $foTargets = @()
        foreach ($e in $finOpsDetected) {
            if ((Get-Count $foFilterL) -gt 0) {
                if (-not (Test-EnvInList -EnvObj $e -List $foFilterL)) { continue }
            }
            $foTargets += $e
        }

        if ((Get-Count $foTargets) -eq 0) {
            Write-Host 'No Finance and Operations environments to process.'
        }
        else {
            $tgtLabel = '(latest available)'
            if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
            Write-Host ("Environments to inspect     : " + (Get-Count $foTargets))
            Write-Host ("Target version              : " + $tgtLabel)
            Write-Host ("Eligible deployment types   : " + (Format-Scope -Raw $optFinOpsDepTypes -EmptyLabel '(any)'))
            Write-Host 'Each environment is probed separately. Nothing is assumed from another.'

            foreach ($envObj in $foTargets) {
                $foChecked++
                $envNameFo = [string]$envObj.DisplayName
                $envIdFo   = [string]$envObj.Id

                Write-Host ''
                Write-Host ('##[group]F&O: ' + $envNameFo)

                # ---------- Inventory ----------
                $propUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf 'finopsproperties'
                $pr = Invoke-PpRest -Method 'GET' -RequestUri $propUri -Headers $ppHeaders

                if ($pr.Status -lt 200 -or $pr.Status -ge 300) {
                    $foPropsFailed++
                    $codeText = Get-ApiErrorCode -Response $pr
                    if ($codeText -ne '') {
                        Write-Host ('  finopsproperties returned HTTP ' + $pr.Status + ' (' + $codeText + ').')
                    } else {
                        Write-Host ('  finopsproperties returned HTTP ' + $pr.Status + '.')
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                $curVer = ''; $platVer = ''; $depType = ''
                $aosInt = ''; $aosBatch = ''; $demo = ''; $sched = @()

                if ($pr.Json) {
                    if ($pr.Json.applicationVersion) { $curVer  = [string]$pr.Json.applicationVersion }
                    if ($pr.Json.platformVersion)    { $platVer = [string]$pr.Json.platformVersion }
                    if ($pr.Json.deploymentType)     { $depType = [string]$pr.Json.deploymentType }
                    if ($null -ne $pr.Json.lastObservedAOSCount -and $pr.Json.maxAOSCount) {
                        $aosInt = [string]$pr.Json.lastObservedAOSCount + ' / ' + [string]$pr.Json.maxAOSCount
                    }
                    if ($null -ne $pr.Json.lastObservedBatchAOSCount -and $pr.Json.maxBatchAOSCount) {
                        $aosBatch = [string]$pr.Json.lastObservedBatchAOSCount + ' / ' + [string]$pr.Json.maxBatchAOSCount
                    }
                    if ($pr.Json.demoDataset)      { $demo  = [string]$pr.Json.demoDataset }
                    if ($pr.Json.scheduledActions) { $sched = @($pr.Json.scheduledActions) }
                }

                Write-Host ('  Application version : ' + $curVer)
                if ($platVer  -ne '') { Write-Host ('  Platform version    : ' + $platVer) }
                if ($depType  -ne '') { Write-Host ('  Deployment type     : ' + $depType) }
                if ($aosInt   -ne '') { Write-Host ('  AOS (interactive)   : ' + $aosInt) }
                if ($aosBatch -ne '') { Write-Host ('  AOS (batch)         : ' + $aosBatch) }
                if ($demo     -ne '') { Write-Host ('  Demo dataset        : ' + $demo) }
                if ((Get-Count $sched) -gt 0) { Write-Host ('  Scheduled actions   : ' + (Get-Count $sched)) }
                else { Write-Host '  Scheduled actions   : none' }

                $rowNote = ''

                # ---------- Eligibility by deployment type ----------
                $eligible = $true
                if ((Get-Count $foDepTypesL) -gt 0) {
                    $eligible = $false
                    foreach ($dt in $foDepTypesL) {
                        if ($depType -ieq ([string]$dt)) { $eligible = $true; break }
                    }
                }

                if (-not $eligible) {
                    $foNotEligible++
                    $rowNote = 'version apply skipped (' + $depType + ')'
                    if ($depType -like 'LCS*') {
                        Write-Host '  Version apply skipped. LCS managed environments are updated through'
                        Write-Host '  Lifecycle Services, not the Power Platform API. Inventory only.'
                    }
                    else {
                        Write-Host ('  Version apply skipped. Deployment type ' + $depType + ' is not in FinOpsDeploymentTypes.')
                    }
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                # ---------- Available versions (probed per environment) ----------
                $verUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf 'finopsversions'
                $vr = Invoke-PpRest -Method 'GET' -RequestUri $verUri -Headers $ppHeaders

                if ($vr.Status -lt 200 -or $vr.Status -ge 300) {
                    $codeText = Get-ApiErrorCode -Response $vr
                    if ($codeText -eq 'RouteNotFound') {
                        $foNoVersions++
                        $rowNote = 'versions: RouteNotFound'
                        Write-Host '  finopsversions returned HTTP 404 RouteNotFound.'
                        Write-Host '  finopsproperties succeeded for this environment, so the token, the'
                        Write-Host '  environment id and the api-version are accepted. This specific route'
                        Write-Host '  did not resolve on this endpoint.'
                    }
                    elseif ($vr.Status -eq 403) {
                        $foFailed++
                        $rowNote = 'versions: 403'
                        Write-Host '  finopsversions returned HTTP 403. The service principal lacks permission.'
                    }
                    else {
                        $foFailed++
                        $rowNote = 'versions: HTTP ' + $vr.Status
                        if ($codeText -ne '') { Write-Host ('  finopsversions returned HTTP ' + $vr.Status + ' (' + $codeText + ').') }
                        else { Write-Host ('  finopsversions returned HTTP ' + $vr.Status + '.') }
                    }
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                $availableVersions = @(ConvertTo-FinOpsVersionList -Json $vr.Json)
                if ((Get-Count $availableVersions) -eq 0) {
                    $foNoVersions++
                    $rowNote = 'no versions returned'
                    Write-Host '  finopsversions returned HTTP 200 but no versions were listed.'
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                Write-Host ('  Available versions  : ' + (Join-Names $availableVersions))

                $target = $optFinOpsTarget
                if ($target -eq '') {
                    $target = Select-HighestVersion -Versions $availableVersions
                    Write-Host ('  Latest available    : ' + [string]$target)
                }
                elseif ($availableVersions -notcontains $target) {
                    $foFailed++
                    $rowNote = 'target not available'
                    Write-Warning ("  Requested version '" + $target + "' is not available here.")
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                if ($curVer -ne '' -and $target -and -not (Test-UpdateAvailable -Available ([string]$target) -Installed $curVer)) {
                    $rowNote = 'up to date'
                    Write-Host ('  Already at or above ' + [string]$target + '. Nothing to apply.')
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

                # ---------- Apply ----------
                if ($optPlanOnly) {
                    $foApplied++
                    $rowNote = 'would apply ' + [string]$target
                    Write-Host ('  [WhatIf] would apply F&O version ' + [string]$target + '.')
                }
                else {
                    $applyUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf ('finopsversions/' + [string]$target + '/apply')
                    $ar = Invoke-PpRest -Method 'POST' -RequestUri $applyUri -Headers $ppHeaders
                    if ($ar.Status -eq 202) {
                        $foApplied++
                        $rowNote = 'applying ' + [string]$target
                        Write-Host ('  Accepted (202). Applying ' + [string]$target + '. Long-running operation.')
                        if ($ar.Json -and $ar.Json.operationId) { Write-Host ('  Operation id        : ' + [string]$ar.Json.operationId) }
                    }
                    elseif ($ar.Status -eq 204) {
                        $rowNote = 'up to date (204)'
                        Write-Host '  No content (204). Already at or above the requested version.'
                    }
                    else {
                        $foFailed++
                        $codeText = Get-ApiErrorCode -Response $ar
                        $rowNote = 'apply: HTTP ' + $ar.Status
                        if ($codeText -ne '') { Write-Host ('  Apply returned HTTP ' + $ar.Status + ' (' + $codeText + ').') }
                        else { Write-Host ('  Apply returned HTTP ' + $ar.Status + '.') }
                    }
                }

                $foInventory += [pscustomobject]@{
                    Environment = $envNameFo; Application = $curVer; Platform = $platVer
                    Deployment = $depType; AOS = $aosInt; Note = $rowNote
                }
                Write-Host '##[endgroup]'
            }

            if ((Get-Count $foInventory) -gt 0) {
                Write-Host ''
                Write-Host '##[group]Finance and Operations inventory'
                $foInventory | Sort-Object Deployment, Environment | Format-Table Environment, Application, Platform, Deployment, AOS, Note -AutoSize | Out-String | Write-Host
                Write-Host '##[endgroup]'
            }
        }
    }
    catch { Write-Host ("##[warning]F&O phase error (non-fatal): " + $_.Exception.Message) }
}

# ============================ SUMMARY ============================
Write-Host ''
Write-Host '##[section]============================================================'
Write-Host '##[section]TENANT SUMMARY'
Write-Host '##[section]============================================================'
Write-Host "Environments processed:         $totalEnvironments"
Write-Host "Apps with updates available:    $totalUpdates"
Write-Host "Failed installs retried:        $totalRetries"
Write-Host "Update operations triggered:    $totalOperations"
Write-Host "Already up to date:             $totalUpToDate"
Write-Host "No matching solution (skipped): $totalNoMatch"
Write-Host "App excluded (skipped):         $totalExcluded"
Write-Host "Manual install required:        $totalManual"
Write-Host "Failures/warnings:              $totalFailed"
Write-Host "F&O environments detected:      $(Get-Count $finOpsDetected)"
if ($optDoFinOps) {
    Write-Host "F&O environments inspected:     $foChecked"
    Write-Host "F&O inventory collected:        $(Get-Count $foInventory)"
    if ($foPropsFailed -gt 0) { Write-Host "F&O properties unavailable:     $foPropsFailed" }
    Write-Host "Version apply skipped (type):   $foNotEligible"
    Write-Host "No version list returned:       $foNoVersions"
    Write-Host "F&O versions applied/planned:   $foApplied"
    Write-Host "F&O failures:                   $foFailed"
}
elseif ((Get-Count $finOpsDetected) -gt 0) {
    Write-Host "F&O phase:                      disabled (set updateFinOpsVersion = true)"
}

if ((Get-Count $manualList) -gt 0) {
    Write-Host ''
    Write-Host '##[group]Manual install required (use Power Platform Admin Center)'
    $manualList | Sort-Object Environment, App | Format-Table Environment, App, Installed, Available -AutoSize | Out-String | Write-Host
    Write-Host 'These apps use a Custom Install Experience and cannot be installed by the API.'
    Write-Host '##[endgroup]'
}

Write-Host ''
Write-Host 'All environments processed'

$global:LASTEXITCODE = 0
exit 0
