<#
.SYNOPSIS
    Updates all Dynamics 365 first-party (Dataverse) apps across every
    environment on a tenant, reports Finance and Operations inventory, and
    optionally applies F&O application versions on eligible environments.

.DESCRIPTION
    Phase 1 (always runs)
      Discovers every Dataverse environment, reads available application
      packages, reads installed versions from Dataverse managed solutions,
      and installs updates where a strictly newer version exists.

    Phase 2 - Finance and Operations
      a. INVENTORY - always runs, read-only, no switch. Reports application
         version, platform version, deployment type, AOS counts, demo
         dataset and scheduled actions for every environment where F&O is
         installed, then prints a consolidated table. It costs one GET per
         F&O environment and changes nothing, so it is not worth gating.
      b. VERSION APPLY - controlled by FinOpsApplyVersion, default false.
         This is the ONLY switch in the Finance and Operations phase, and
         the only way a version is ever applied. It changes the
         environment. Only eligible deployment types are considered. LCS
         managed environments (LCSSandbox, LCSProduction) are deliberately
         excluded because their application updates are driven through
         Lifecycle Services, not the Power Platform API.

      Version apply is gated behind a live route check, so it begins
      working automatically once the finopsversions route is available on
      an endpoint. That is exactly why it must be set explicitly: nothing
      else - no default, no legacy variable, no platform change - can turn
      it on.

.NOTES
    v2.3.0
      - FinOpsApplyVersion is the single Finance and Operations variable.
        Inventory always runs and is read-only. There is no separate switch
        for it, and no legacy alias. If a variable named FinOpsInventory or
        UpdateFinOpsVersion is present in the environment, it is ignored
        and the script says so once in the log.
      - PollIntervalSec and PollTimeoutMin removed. They were resolved but
        never read; no polling loop existed. Rather than keep dead settings
        that the documentation described as real behaviour, they are gone.
        Install completion polling may return once the operation status
        route is confirmed against a live endpoint.
      - Transport failures are now reported as transport failures instead of
        being rendered as "HTTP -1".
      - The Finance and Operations phase requires PowerShell 7. On Windows
        PowerShell 5.1 it is skipped with a clear message instead of failing
        obscurely inside Invoke-WebRequest.

    v2.2.0
      - Every environment is probed individually. An earlier build stopped
        after the first RouteNotFound and assumed the rest would behave the
        same, which hid per deployment type differences. A 404 over REST
        costs about 25 ms, so probing all of them is effectively free.
      - Reporting is factual. The script states what the API returned
        (for example RouteNotFound) rather than asserting a cause.
      - FinOpsDeploymentTypes controls which deployment types are eligible
        for a version apply. Default excludes LCS managed environments.

    Verified against a live tenant (westeurope, app-only token), reproduced
    independently via both raw REST calls and the `pac dynamics` CLI:
      GET  /dynamics/environments/{id}/finopsproperties            -> HTTP 200
      GET  /dynamics/environments/{id}/finopsversions               -> HTTP 404 RouteNotFound
      POST /dynamics/environments/{id}/finopsversions/{v}/apply     -> HTTP 404 RouteNotFound
    finopsproperties succeeding on the identical token, environment id and
    api-version rules out auth, tenant and environment id as the cause.
    The versions route and its apply sub-route are simply not deployed to
    this endpoint yet. This is not asserted in the log as the cause of a
    404; the log only ever states what the API returned.

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

    [Parameter()] [string] $DumpDiagnostics     = '',
    [Parameter()] [string] $RetryFailedInstalls = '',
    [Parameter()] [string] $WhatIf              = '',
    [Parameter()] [string] $EnvironmentFilter   = '',
    [Parameter()] [string] $EnvironmentExclude  = '',
    [Parameter()] [string] $AppExclude          = '',
    [Parameter()] [string] $UsePacFallback      = '',

    # The ONLY Finance and Operations switch. Default false.
    # Inventory always runs and is read-only, so it has no switch.
    [Parameter()] [string] $FinOpsApplyVersion      = '',

    # Supporting settings for the apply. They refine WHAT and WHERE, but
    # none of them can enable an apply on their own.
    [Parameter()] [string] $FinOpsTargetVersion     = '',
    [Parameter()] [string] $FinOpsEnvironmentFilter = '',
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
    DumpDiagnostics         = 'true'
    RetryFailedInstalls     = 'true'
    WhatIf                  = 'false'
    EnvironmentFilter       = ''
    EnvironmentExclude      = ''
    AppExclude              = ''
    UsePacFallback          = 'false'
    FinOpsApplyVersion      = 'false'
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

# ---------------------------------------------------------------------
# Settings resolution
# ---------------------------------------------------------------------
$cfgAuthority  = Resolve-Setting $Authority               'Authority'               "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$cfgBapRoot    = Resolve-Setting $BapApiRoot              'BapApiRoot'              $Defaults.BapApiRoot
$cfgBapVersion = Resolve-Setting $BapApiVersion           'BapApiVersion'           $Defaults.BapApiVersion
$cfgPpScope    = Resolve-Setting $PowerPlatformScope      'PowerPlatformScope'      $Defaults.PowerPlatformScope
$cfgPpRoot     = Resolve-Setting $PpApiRoot               'PpApiRoot'               $Defaults.PpApiRoot
$cfgAppMgmtVer = Resolve-Setting $AppManagementApiVersion 'AppManagementApiVersion' $Defaults.AppManagementApiVersion
$cfgFinOpsVer  = Resolve-Setting $FinOpsApiVersion        'FinOpsApiVersion'        $Defaults.FinOpsApiVersion

$optDumpDiag   = ConvertTo-Bool (Resolve-Setting     $DumpDiagnostics     'DumpDiagnostics'     $Defaults.DumpDiagnostics)
$optRetry      = ConvertTo-Bool (Resolve-Setting     $RetryFailedInstalls 'RetryFailedInstalls' $Defaults.RetryFailedInstalls)
$optPlanOnly   = ConvertTo-Bool (Resolve-Overridable $WhatIf         'WhatIfOverride'         'WhatIf'         $Defaults.WhatIf)
$optUsePac     = ConvertTo-Bool (Resolve-Overridable $UsePacFallback 'UsePacFallbackOverride' 'UsePacFallback' $Defaults.UsePacFallback)
$optEnvFilter  = Resolve-Setting $EnvironmentFilter  'EnvironmentFilter'  $Defaults.EnvironmentFilter
$optEnvExclude = Resolve-Setting $EnvironmentExclude 'EnvironmentExclude' $Defaults.EnvironmentExclude
$optAppExclude = Resolve-Setting $AppExclude         'AppExclude'         $Defaults.AppExclude

# Finance and Operations: ONE switch.
# Precedence: queue-time override, then library variable, then false.
$optDoApply = ConvertTo-Bool (Resolve-Overridable $FinOpsApplyVersion 'FinOpsApplyVersionOverride' 'FinOpsApplyVersion' $Defaults.FinOpsApplyVersion)

$optFinOpsTarget   = Resolve-Overridable $FinOpsTargetVersion 'FinOpsTargetVersionOverride' 'FinOpsTargetVersion' $Defaults.FinOpsTargetVersion
$optFinOpsEnvList  = Resolve-Setting     $FinOpsEnvironmentFilter 'FinOpsEnvironmentFilter' $Defaults.FinOpsEnvironmentFilter
$optFinOpsDepTypes = Resolve-Setting     $FinOpsDeploymentTypes   'FinOpsDeploymentTypes'   $Defaults.FinOpsDeploymentTypes

# Retired variables. If either is still sitting in a variable group, say so
# once so nobody believes it is still doing something.
$optRetiredVars = @()
foreach ($retired in @('UpdateFinOpsVersion','FinOpsInventory')) {
    $rv = [Environment]::GetEnvironmentVariable($retired)
    if ((Get-OrDefault $rv '__unset__') -ne '__unset__') { $optRetiredVars += $retired }
}

# The Finance and Operations phase uses Invoke-WebRequest -SkipHttpErrorCheck,
# which is PowerShell 7 only. Phase 1 runs fine on 5.1.
$optPs7      = ($PSVersionTable.PSVersion.Major -ge 7)
$optDoFinOps = $true
if (-not $optPs7) { $optDoFinOps = $false; $optDoApply = $false }

$Config = [ordered]@{
    Authority               = $cfgAuthority
    BapApiRoot              = $cfgBapRoot.TrimEnd('/')
    BapScope                = "$($cfgBapRoot.TrimEnd('/'))/.default"
    BapApiVersion           = $cfgBapVersion
    PowerPlatformScope      = $cfgPpScope
    PpApiRoot               = $cfgPpRoot.TrimEnd('/')
    AppManagementApiVersion = $cfgAppMgmtVer
    FinOpsApiVersion        = $cfgFinOpsVer
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
# Status is the real HTTP status code. A request that never produced a
# response (DNS, TLS, timeout, unsupported parameter) is reported with
# Transport = $true rather than a fake status code.
function Invoke-PpRest {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)] [string] $RequestUri,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [string] $Body = ''
    )
    $status    = 0
    $text      = ''
    $transport = $false
    try {
        $p = @{ Method = $Method; Uri = $RequestUri; Headers = $Headers; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
        if ($Body -ne '') { $p['Body'] = $Body; $p['ContentType'] = 'application/json' }
        $r = Invoke-WebRequest @p
        $status = [int]$r.StatusCode
        if ($null -ne $r.Content) { $text = [string]$r.Content }
    }
    catch {
        $transport = $true
        $text = (Get-ErrorText -ErrorRecord $_)
    }

    $json = $null
    if ($text -ne '') {
        $t = $text.Trim()
        $i = $t.IndexOfAny([char[]]@('{','['))
        if ($i -ge 0) { try { $json = $t.Substring($i) | ConvertFrom-Json } catch { $json = $null } }
    }
    return [pscustomobject]@{ Status = $status; Text = $text; Json = $json; Transport = $transport }
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

# One consistent sentence for a failed call, whether it failed at the
# transport layer or returned an HTTP error status.
function Format-RestFailure {
    param([string] $Leaf, $Response)
    if ($null -eq $Response) { return "$Leaf failed with no response object." }
    if ($Response.Transport) {
        $detail = [string]$Response.Text
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }
        return "$Leaf request failed before any HTTP response was received. $detail"
    }
    $codeText = Get-ApiErrorCode -Response $Response
    if ($codeText -ne '') { return "$Leaf returned HTTP $($Response.Status) ($codeText)." }
    return "$Leaf returned HTTP $($Response.Status)."
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
                        Write-Host ("  [solution] {0} | {1} | {2}" -f $s.uniquename, $s.friendlyname, $s.version); break
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

# Matching order: exact, then wildcard when the needle contains '*', then
# substring. Substring is deliberately last and is the loosest form; a short
# needle will match broadly. See docs/parameters.md.
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
Write-Host ("  FinOpsApplyVersion      : " + $optDoApply)
Write-Host ("  FinOpsApiVersion        : " + $Config.FinOpsApiVersion)
Write-Host ("  FinOpsEnvironmentFilter : " + (Format-Scope -Raw $optFinOpsEnvList -EmptyLabel '(all detected F&O environments)'))
if ($optDoApply) {
    $tgtLabel = '(latest available)'
    if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
    Write-Host ("  FinOpsTargetVersion     : " + $tgtLabel)
    Write-Host ("  FinOpsDeploymentTypes   : " + (Format-Scope -Raw $optFinOpsDepTypes -EmptyLabel '(any)'))
}
Write-Host '  Note: F&O inventory always runs and is read-only.'
Write-Host '  Note: LCS managed environments are inventoried but never version-updated.'

# Notices come after the settings block, so they never split it in the log.
if ((Get-Count $optRetiredVars) -gt 0) {
    Write-Host ''
    Write-Warning ("These variables no longer exist and are ignored: " + (Join-Names $optRetiredVars) + ".")
    Write-Warning 'Finance and Operations has a single switch: finOpsApplyVersion. Inventory always runs and is read-only.'
    Write-Warning 'Remove the retired variables from the variable group to silence this message.'
}

if (-not $optPs7) {
    Write-Host ''
    Write-Warning 'The Finance and Operations phase requires PowerShell 7 and will be skipped.'
    Write-Warning "Detected PowerShell $($PSVersionTable.PSVersion). Run the pipeline task with pwsh: true."
}

if ($optDoApply) {
    Write-Host ''
    Write-Host '##[warning]Finance and Operations version apply is ENABLED by finOpsApplyVersion = true.'
    Write-Host '##[warning]Eligible environments will be moved to a new application version.'
    Write-Host '##[warning]This is a long-running operation and affects availability.'
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
                Write-Host ("  - {0} [{1}]  installed: {2}  available: {3}" -f $c.localizedName, $c.uniqueName, $ivText, $c.version)
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
        foreach ($nm in $noMatchNames) { Write-Host "  - $nm" }
        Write-Host '##[endgroup]'
    }

    Write-Host ''
    Write-Host "Environment summary -> updates: $envUpdates | failed-retries: $envRetries | up-to-date: $envUpToDate | no solution match: $envNoMatch | app-excluded: $envExcluded | manual: $envManual"
}

# ======= PHASE 2: Finance and Operations inventory and version apply =======
#
# Inventory always runs and is read-only.
# Version apply runs only when FinOpsApplyVersion is true AND the deployment
# type is eligible.
#
# Every F&O environment is probed individually. Nothing is assumed from the
# result of another environment. Reporting states what the API returned.

$foInventory    = @()
$foChecked      = 0
$foApplied      = 0
$foFailed       = 0
$foPropsFailed  = 0
$foNotEligible  = 0
$foNoVersions   = 0
$foRouteMissing = 0

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
            Write-Host ("Environments to inspect     : " + (Get-Count $foTargets))
            if ($optDoApply) {
                $tgtLabel = '(latest available)'
                if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
                Write-Host ("Mode                        : inventory + version apply")
                Write-Host ("Target version              : " + $tgtLabel)
                Write-Host ("Eligible deployment types   : " + (Format-Scope -Raw $optFinOpsDepTypes -EmptyLabel '(any)'))
            }
            else {
                Write-Host ("Mode                        : inventory only (read-only)")
                Write-Host  "Version apply               : off (set finOpsApplyVersion = true to enable)"
            }
            Write-Host 'Each environment is probed separately. Nothing is assumed from another.'

            foreach ($envObj in $foTargets) {
                $foChecked++
                $envNameFo = [string]$envObj.DisplayName
                $envIdFo   = [string]$envObj.Id

                Write-Host ''
                Write-Host ('##[group]F&O: ' + $envNameFo)

                # ---------- Inventory (also supplies data the apply needs) ----------
                $propUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf 'finopsproperties'
                $pr = Invoke-PpRest -Method 'GET' -RequestUri $propUri -Headers $ppHeaders
                if ($pr.Transport -or $pr.Status -lt 200 -or $pr.Status -ge 300) {
                    $foPropsFailed++
                    Write-Host ('  ' + (Format-RestFailure -Leaf 'finopsproperties' -Response $pr))
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

                $rowNote = 'inventory only'

                # ---------- Stop here when version apply is off ----------
                if (-not $optDoApply) {
                    $foInventory += [pscustomobject]@{
                        Environment = $envNameFo; Application = $curVer; Platform = $platVer
                        Deployment = $depType; AOS = $aosInt; Note = $rowNote
                    }
                    Write-Host '##[endgroup]'
                    continue
                }

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
                if ($vr.Transport -or $vr.Status -lt 200 -or $vr.Status -ge 300) {
                    $codeText = Get-ApiErrorCode -Response $vr
                    if (-not $vr.Transport -and $codeText -eq 'RouteNotFound') {
                        $foRouteMissing++
                        $rowNote = 'versions: RouteNotFound'
                        Write-Host '  finopsversions returned HTTP 404 RouteNotFound.'
                        Write-Host '  finopsproperties succeeded for this environment, so the token, the'
                        Write-Host '  environment id and the api-version are accepted. This specific route'
                        Write-Host '  did not resolve on this endpoint.'
                    }
                    elseif (-not $vr.Transport -and $vr.Status -eq 403) {
                        $foFailed++
                        $rowNote = 'versions: 403'
                        Write-Host '  finopsversions returned HTTP 403. The service principal lacks permission.'
                    }
                    else {
                        $foFailed++
                        if ($vr.Transport) { $rowNote = 'versions: transport failure' }
                        else { $rowNote = 'versions: HTTP ' + $vr.Status }
                        Write-Host ('  ' + (Format-RestFailure -Leaf 'finopsversions' -Response $vr))
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
                    if (-not $ar.Transport -and $ar.Status -eq 202) {
                        $foApplied++
                        $rowNote = 'applying ' + [string]$target
                        Write-Host ('  Accepted (202). Applying ' + [string]$target + '. Long-running operation.')
                        if ($ar.Json -and $ar.Json.operationId) { Write-Host ('  Operation id        : ' + [string]$ar.Json.operationId) }
                    }
                    elseif (-not $ar.Transport -and $ar.Status -eq 204) {
                        $rowNote = 'up to date (204)'
                        Write-Host '  No content (204). Already at or above the requested version.'
                    }
                    else {
                        $foFailed++
                        if ($ar.Transport) { $rowNote = 'apply: transport failure' }
                        else { $rowNote = 'apply: HTTP ' + $ar.Status }
                        Write-Host ('  ' + (Format-RestFailure -Leaf 'apply' -Response $ar))
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
    if ($optDoApply) {
        Write-Host "Version apply skipped (type):   $foNotEligible"
        Write-Host "Versions route unavailable:     $foRouteMissing"
        Write-Host "Versions list empty (HTTP 200): $foNoVersions"
        Write-Host "F&O versions applied/planned:   $foApplied"
    }
    else {
        Write-Host "Version apply:                  off (set finOpsApplyVersion = true)"
    }
    Write-Host "F&O failures:                   $foFailed"
}
else {
    Write-Host "F&O phase:                      skipped (PowerShell 7 required)"
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
