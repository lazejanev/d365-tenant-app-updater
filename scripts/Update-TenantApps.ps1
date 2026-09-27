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
      The Finance and Operations Provisioning App Anchor Solution is
      EXCLUDED from this phase's install attempts (always rejected by the
      generic App Management API; exclusively owned by Phase 2).

    Phase 2 - Finance and Operations
      a. INVENTORY - always runs, read-only, no switch. Reports the live
         application version (finopsproperties, fetched fresh every run),
         platform version, deployment type, and AOS counts for every
         environment where F&O is installed.
      b. VERSION APPLY - controlled by FinOpsApplyVersion, default false.
         The ONLY switch in this phase. Changes the environment. Only
         eligible deployment types are considered. LCS managed
         environments are excluded (updated via Lifecycle Services, not
         this API).
         FinOpsUpdateScope (default QualityUpdate) restricts which KIND of
         available version may be selected, using Microsoft's own
         releaseStage label on each version - see v2.4.0 notes.

.NOTES
    v2.4.0
      - REMOVED all classification logic based on the F&O Provisioning App
        Anchor Solution (Get-FinOpsVersionChangeType, and every message
        that referenced "Anchor Solution" as a basis for a decision).
        Confirmed live, across ten environments in one run: every one of
        them shares the IDENTICAL live application build (10.0.2645.136),
        yet their Anchor Solution readings split into two different, wrong
        values (10.0.48.6 and 10.0.48.7). This is not a timing lag - it is
        that the Anchor Solution's version in Dataverse is only set when a
        Dataverse-level solution operation touches it (an environment copy
        from an already-updated source, or an explicit solution import),
        and is NOT updated by Microsoft's own automated Unified
        environment service update rollout, which is how these
        environments actually get updated in practice. The Anchor Solution
        was therefore never a safe basis for deciding what kind of update
        is available, and this script no longer uses it for that purpose
        at all.
      - REPLACED it with Microsoft's own releaseStage field, present on
        every entry returned by finopsversions (confirmed in a raw
        response captured earlier this session: {"version":"10.0.48.7",
        "releaseStage":"QualityUpdate"}, alongside a second entry staged
        "GeneralAvailability"). This field is the platform's own
        classification of each version, computed against the environment's
        true live state - there is nothing left for this script to derive
        or guess. FinOpsUpdateScope now matches directly against it:
          QualityUpdate  -> only versions staged QualityUpdate
          VersionUpdate  -> only versions NOT staged QualityUpdate
          Any            -> every version, ignoring stage
      - REWROTE all Finance and Operations log output to be dramatically
        shorter, in direct response to feedback that the previous format
        repeated the same explanatory sentence in full on every single
        environment line, making 13 environments unreadable at a glance.
        Explanatory text now appears ONCE, in a short legend printed at
        the start of the Finance and Operations section. Per-environment
        output is now one compact headline (also the collapsible group's
        label, so it is visible even collapsed) with no repeated prose.
      - The Anchor Solution figure is still shown, but only as a single,
        clearly-labeled, non-decisive diagnostic value under
        DumpDiagnostics, never in a headline, and never used to accept,
        reject, or classify anything.

    v2.3.9 (superseded by v2.4.0 above)
      - Had kept the Anchor Solution as the classification reference,
        merely labeling it as "can lag". Live data now shows the problem
        is structural, not a lag, for environments updated by Microsoft's
        own automated rollout rather than a Dataverse solution operation -
        so labeling it as potentially stale was insufficient; it needed to
        be removed from the decision path entirely.

    v2.3.8
      - Collapsible ##[group] per environment, with the group's label set
        to the headline so Azure DevOps shows the outcome even collapsed.

    v2.3.5
      - The F&O Provisioning App Anchor Solution is excluded from Phase
        1's generic install loop (it is exclusively owned by Phase 2).

    v2.3.1
      - The apply call's own response (202/204) is the sole authority on
        whether an apply is needed. No client-side pre-check of any kind.

    v2.3.0
      - FinOpsApplyVersion is the single Finance and Operations ON/OFF
        switch. The Finance and Operations phase requires PowerShell 7.

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
    [Parameter()] [string] $DumpSolutionCatalog  = '',
    [Parameter()] [string] $RetryFailedInstalls = '',
    [Parameter()] [string] $WhatIf              = '',
    [Parameter()] [string] $EnvironmentFilter   = '',
    [Parameter()] [string] $EnvironmentExclude  = '',
    [Parameter()] [string] $AppExclude          = '',
    [Parameter()] [string] $UsePacFallback      = '',

    [Parameter()] [string] $FinOpsApplyVersion      = '',
    [Parameter()] [string] $FinOpsTargetVersion     = '',
    [Parameter()] [string] $FinOpsEnvironmentFilter = '',
    [Parameter()] [string] $FinOpsDeploymentTypes   = '',

    # Restricts WHICH KIND of available version apply may select, matched
    # against Microsoft's own releaseStage label on each version:
    #   QualityUpdate (default) - only versions staged QualityUpdate
    #   VersionUpdate           - only versions NOT staged QualityUpdate
    #   Any                     - numerically highest, ignoring stage
    [Parameter()] [string] $FinOpsUpdateScope       = ''
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
    DumpSolutionCatalog     = 'false'
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
    FinOpsUpdateScope       = 'QualityUpdate'
}

$FinOpsUpdateScopeValues = @('QualityUpdate','VersionUpdate','Any')

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

$optDumpDiag    = ConvertTo-Bool (Resolve-Setting     $DumpDiagnostics     'DumpDiagnostics'     $Defaults.DumpDiagnostics)
$optDumpCatalog = ConvertTo-Bool (Resolve-Setting     $DumpSolutionCatalog 'DumpSolutionCatalog' $Defaults.DumpSolutionCatalog)
$optRetry       = ConvertTo-Bool (Resolve-Setting     $RetryFailedInstalls 'RetryFailedInstalls' $Defaults.RetryFailedInstalls)
$optPlanOnly    = ConvertTo-Bool (Resolve-Overridable $WhatIf         'WhatIfOverride'         'WhatIf'         $Defaults.WhatIf)
$optUsePac      = ConvertTo-Bool (Resolve-Overridable $UsePacFallback 'UsePacFallbackOverride' 'UsePacFallback' $Defaults.UsePacFallback)
$optEnvFilter   = Resolve-Setting $EnvironmentFilter  'EnvironmentFilter'  $Defaults.EnvironmentFilter
$optEnvExclude  = Resolve-Setting $EnvironmentExclude 'EnvironmentExclude' $Defaults.EnvironmentExclude
$optAppExclude  = Resolve-Setting $AppExclude         'AppExclude'         $Defaults.AppExclude

$optDoApply = ConvertTo-Bool (Resolve-Overridable $FinOpsApplyVersion 'FinOpsApplyVersionOverride' 'FinOpsApplyVersion' $Defaults.FinOpsApplyVersion)

$optFinOpsTarget   = Resolve-Overridable $FinOpsTargetVersion 'FinOpsTargetVersionOverride' 'FinOpsTargetVersion' $Defaults.FinOpsTargetVersion
$optFinOpsEnvList  = Resolve-Setting     $FinOpsEnvironmentFilter 'FinOpsEnvironmentFilter' $Defaults.FinOpsEnvironmentFilter
$optFinOpsDepTypes = Resolve-Setting     $FinOpsDeploymentTypes   'FinOpsDeploymentTypes'   $Defaults.FinOpsDeploymentTypes

$optFinOpsScopeRaw = Resolve-Overridable $FinOpsUpdateScope 'FinOpsUpdateScopeOverride' 'FinOpsUpdateScope' $Defaults.FinOpsUpdateScope
$optFinOpsScope    = $Defaults.FinOpsUpdateScope
$optFinOpsScopeWasInvalid = $false
foreach ($v in $FinOpsUpdateScopeValues) {
    if ($optFinOpsScopeRaw -ieq $v) { $optFinOpsScope = $v; break }
}
if (-not ($FinOpsUpdateScopeValues | Where-Object { $_ -ieq $optFinOpsScopeRaw })) {
    $optFinOpsScopeWasInvalid = ($optFinOpsScopeRaw -ne $Defaults.FinOpsUpdateScope)
}

$optRetiredVars = @()
foreach ($retired in @('UpdateFinOpsVersion','FinOpsInventory')) {
    $rv = [Environment]::GetEnvironmentVariable($retired)
    if ((Get-OrDefault $rv '__unset__') -ne '__unset__') { $optRetiredVars += $retired }
}

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

function Get-ApiErrorCode {
    param($Response)
    if ($null -eq $Response) { return '' }
    if ($Response.Json -and $Response.Json.code)       { return [string]$Response.Json.code }
    if ($Response.Json -and $Response.Json.error -and $Response.Json.error.code) { return [string]$Response.Json.error.code }
    if ($Response.Text -and ([string]$Response.Text) -match 'does not match any known API routes') { return 'RouteNotFound' }
    return ''
}

function Format-RestFailure {
    param([string] $Leaf, $Response)
    if ($null -eq $Response) { return "$Leaf failed with no response object." }
    if ($Response.Transport) {
        $detail = [string]$Response.Text
        if ($detail.Length -gt 200) { $detail = $detail.Substring(0, 200) + '...' }
        return "transport failure. $detail"
    }
    $codeText = Get-ApiErrorCode -Response $Response
    if ($codeText -ne '') { return "HTTP $($Response.Status) ($codeText)" }
    return "HTTP $($Response.Status)"
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

function Test-EnvironmentNotEnabled {
    param([AllowEmptyString()] [string] $Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    $m = $Message.ToLowerInvariant()
    return ($m -match 'is not enabled') -or ($m -match 'environment is disabled') -or ($m -match 'admin ?mode')
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

function Get-FinOpsMarkerPackage {
    param($Packages)
    $markers = @('msdyn_financeandoperationsprovisioningapp','financeandoperationsprovisioning','dynamics365financeandoperations')
    foreach ($p in @($Packages)) {
        $state = [string]$p.state
        if ($state -ne 'Installed' -and $state -ne 'InstallFailed') { continue }
        $un = ([string]$p.uniqueName).ToLower()
        $ln = ([string]$p.localizedName).ToLower()
        foreach ($m in $markers) {
            if ($un.Contains($m)) { return $p }
        }
        if ($ln.Contains('finance and operations') -and -not $ln.Contains('package manager')) {
            return $p
        }
    }
    return $null
}

# Returns an array of [pscustomobject]@{ Version; ReleaseStage } - the
# releaseStage is Microsoft's OWN classification of each version, read
# directly from the response, not derived by this script. An entry with
# no releaseStage field gets 'Unknown' rather than being guessed at.
function ConvertTo-FinOpsVersionList {
    param($Json)
    if ($null -eq $Json) { return @() }
    $items = $Json
    foreach ($p in @('availableVersions','value','versions','items','data')) {
        if ($Json.$p) { $items = $Json.$p; break }
    }
    $out = @()
    $seen = @{}
    foreach ($i in @($items)) {
        $v = $null; $stage = 'Unknown'
        if ($i -is [string]) { $v = $i }
        else {
            foreach ($p in @('version','applicationVersion','name','value')) {
                if ($i.$p -and ([string]$i.$p) -match '^\d+(\.\d+)+') { $v = [string]$i.$p; break }
            }
            if ($i.releaseStage) { $stage = [string]$i.releaseStage }
        }
        if ($v -and -not $seen.ContainsKey($v)) {
            $seen[$v] = $true
            $out += [pscustomobject]@{ Version = $v; ReleaseStage = $stage }
        }
    }
    return $out
}

# Friendly label for a scope value, matching Microsoft's own terminology
# for these releases (PQU = "proactive quality update", the term used on
# https://learn.microsoft.com/.../quality-updates-schedule). Used only in
# display text; the actual filtering still matches releaseStage exactly.
function Get-FinOpsScopeLabel {
    param([string] $Scope)
    switch ($Scope) {
        'QualityUpdate' { return 'PQU' }
        'VersionUpdate' { return 'version update' }
        default         { return $Scope }
    }
}

function Select-HighestVersion {
    param($Versions)   # array of plain version strings
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
    $tgtLabel = '(highest matching scope)'
    if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
    Write-Host ("  FinOpsTargetVersion     : " + $tgtLabel)
    Write-Host ("  FinOpsDeploymentTypes   : " + (Format-Scope -Raw $optFinOpsDepTypes -EmptyLabel '(any)'))
    Write-Host ("  FinOpsUpdateScope       : " + $optFinOpsScope)
}

if ((Get-Count $optRetiredVars) -gt 0) {
    Write-Host ''
    Write-Warning ("These variables no longer exist and are ignored: " + (Join-Names $optRetiredVars) + ".")
}

if ($optFinOpsScopeWasInvalid) {
    Write-Host ''
    Write-Warning ("finOpsUpdateScope value '" + $optFinOpsScopeRaw + "' is not recognised. Valid values: " + (Join-Names $FinOpsUpdateScopeValues) + ". Falling back to " + $Defaults.FinOpsUpdateScope + ".")
}

if (-not $optPs7) {
    Write-Host ''
    Write-Warning 'The Finance and Operations phase requires PowerShell 7 and will be skipped.'
    Write-Warning "Detected PowerShell $($PSVersionTable.PSVersion). Run the pipeline task with pwsh: true."
}

if ($optDoApply) {
    Write-Host ''
    Write-Host ('##[warning]FINANCE AND OPERATIONS UPDATE IS ENABLED. Scope: ' + $optFinOpsScope + '. This is a long-running operation and affects availability.')
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
$totalAdminModeEnvs = 0; $totalAdminModeSkipped = 0
$solDumped = $false
$manualList         = @()
$adminModeList      = @()
$finOpsDetected     = @()
$finOpsAnchorVersions = @{}   # envId -> Anchor Solution version. Diagnostic only - see v2.4.0. NEVER used to accept/reject/classify anything.

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
        if ($optDumpCatalog -and -not $solDumped) { $hints = @('crm','hub','sales','insight','productivity','globalization','quality','channel','customerservice','outlook') }
        $solMap = Get-SolutionVersionMap -InstanceUrl $instanceUrl -DumpHints $hints
        $solDumped = $true
    }
    catch {
        $totalFailed++
        Write-Host "##[warning]Failed to read Dataverse solution versions for '$envName': $_"
        Write-Host '##[warning]Skipping this environment (no installed data => nothing installed blindly).'
        continue
    }

    $foMarkerPkg = Get-FinOpsMarkerPackage -Packages $available
    if ($foMarkerPkg) {
        $finOpsDetected += $envObj
        $finOpsAnchorVersions[$envId] = Resolve-InstalledVersion -Pkg $foMarkerPkg -Map $solMap -Alias $appSolutionAlias
        Write-Host "Finance and Operations detected. Live version and update status are reported in the Finance and Operations phase below."
    }

    $candidates = @()
    $foMarkerSkipped = 0
    foreach ($p in $available) {
        if (-not $p.uniqueName) { continue }
        if ($p.state -ne 'Installed' -and -not ($optRetry -and $p.state -eq 'InstallFailed')) { continue }
        if ($foMarkerPkg -and $p.uniqueName -eq $foMarkerPkg.uniqueName) { $foMarkerSkipped++; continue }
        $candidates += $p
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
    $envAdminMode = $false; $envAdminModeSkipped = 0

    foreach ($pkg in $candidates) {
        $name = $pkg.uniqueName
        if ($pkg.localizedName) { $name = $pkg.localizedName }
        $avail = [string]$pkg.version

        if (Test-AppExcluded -Pkg $pkg -List $appExcludeL) {
            $envExcluded++; $totalExcluded++
            if ($optDumpDiag) { Write-Host "  Skipping (app excluded): $name" }
            continue
        }

        if ($envAdminMode) { $envAdminModeSkipped++; continue }

        if ($pkg.state -eq 'InstallFailed') {
            $envRetries++; $totalRetries++
            Write-Host ''
            Write-Host "Retrying failed installation: $name  (target version: $avail)"
            if ($optPlanOnly) { Write-Host '  [WhatIf] would retry install.'; continue }
            try { if (Invoke-AppInstall -Pkg $pkg -EnvId $envId -Headers $ppHeaders) { $totalOperations++ } }
            catch {
                $errText = Get-ErrorText -ErrorRecord $_
                if (Test-EnvironmentNotEnabled -Message $errText) {
                    $envAdminMode = $true
                    Write-Host "##[warning]Environment '$envName' is not enabled (Admin Mode). Skipping remaining installs for this environment."
                }
                elseif (Test-CustomInstallExperience -Message $errText) {
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
            if (Test-EnvironmentNotEnabled -Message $errText) {
                $envAdminMode = $true
                Write-Host "##[warning]Environment '$envName' is not enabled (Admin Mode). Skipping remaining installs for this environment."
            }
            elseif (Test-CustomInstallExperience -Message $errText) {
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

    if ($envAdminMode) {
        $totalAdminModeEnvs++
        $totalAdminModeSkipped += $envAdminModeSkipped
        $adminModeList += [pscustomobject]@{ Environment = $envName; Id = $envId; AppsSkipped = $envAdminModeSkipped }
    }

    Write-Host ''
    $summaryLine = "Environment summary -> updates: $envUpdates | failed-retries: $envRetries | up-to-date: $envUpToDate | no solution match: $envNoMatch | app-excluded: $envExcluded | manual: $envManual"
    if ($envAdminMode) { $summaryLine += " | ADMIN MODE: $envAdminModeSkipped app(s) skipped" }
    Write-Host $summaryLine
}

# ======= PHASE 2: Finance and Operations inventory and version apply =======
#
# v2.4.0: classification uses Microsoft's own releaseStage label on each
# finopsversions entry - not the Anchor Solution, which has been confirmed
# unreliable (see the top of this file). Output is one compact line per
# environment; the explanation below is printed ONCE rather than repeated.

function Complete-FoEnvironment {
    param(
        [Parameter(Mandatory)] [string] $EnvName,
        [Parameter(Mandatory)] [string] $Headline,
        [string[]] $Diag = @(),
        [bool]     $ShowDiag,
        [string]   $Application = '',
        [string]   $Platform    = '',
        [string]   $Deployment  = '',
        [string]   $AOS         = '',
        [Parameter(Mandatory)] [string] $Note
    )
    $label = $EnvName + ": " + $Headline
    if ($ShowDiag -and (Get-Count $Diag) -gt 0) {
        Write-Host ('##[group]' + $label)
        foreach ($d in $Diag) { Write-Host ("    " + $d) }
        Write-Host '##[endgroup]'
    }
    else {
        Write-Host $label
    }
    $script:foInventory += [pscustomobject]@{
        Environment = $EnvName; Application = $Application; Platform = $Platform
        Deployment = $Deployment; AOS = $AOS; Note = $Note
    }
}

$foInventory    = @()
$foChecked      = 0
$foApplied      = 0
$foFailed       = 0
$foPropsFailed  = 0
$foNotEligible  = 0
$foNoVersions   = 0
$foRouteMissing = 0
$foScopeFiltered = 0

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
            if ($optDoApply) {
                $tgtLabel = '(highest matching scope)'
                if ($optFinOpsTarget -ne '') { $tgtLabel = $optFinOpsTarget }
                Write-Host ("Environments: " + (Get-Count $foTargets) + " | Apply enabled | Scope: " + $optFinOpsScope + " | Target: " + $tgtLabel)
                Write-Host "Scope is matched against Microsoft's own releaseStage on each available version (QualityUpdate = PQU, a same-train patch; anything else = a new version update / release train)."
                Write-Host "A version is applied only when the apply call itself returns 202; a 204 means the platform confirms nothing is needed. No other check decides this."
            }
            else {
                Write-Host ("Environments: " + (Get-Count $foTargets) + " | Inventory only (set finOpsApplyVersion = true to enable apply)")
            }
            Write-Host ''

            foreach ($envObj in $foTargets) {
                $foChecked++
                $envNameFo = [string]$envObj.DisplayName
                $envIdFo   = [string]$envObj.Id
                $anchorVer = $null
                if ($finOpsAnchorVersions.ContainsKey($envIdFo)) { $anchorVer = $finOpsAnchorVersions[$envIdFo] }

                $propUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf 'finopsproperties'
                $pr = Invoke-PpRest -Method 'GET' -RequestUri $propUri -Headers $ppHeaders
                if ($pr.Transport -or $pr.Status -lt 200 -or $pr.Status -ge 300) {
                    $foPropsFailed++
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag `
                        -Headline ("properties unavailable - " + (Format-RestFailure -Response $pr)) `
                        -Note ('properties: ' + $(if ($pr.Transport) { 'transport failure' } else { 'HTTP ' + $pr.Status }))
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

                # Anchor Solution shown only as a labeled diagnostic value,
                # never used in any decision. See v2.4.0 notes.
                $diag = @()
                if ($aosBatch -ne '') { $diag += ('AOS (batch)     : ' + $aosBatch) }
                if ($demo     -ne '') { $diag += ('Demo dataset    : ' + $demo) }
                if ((Get-Count $sched) -gt 0) { $diag += ('Scheduled       : ' + (Get-Count $sched)) }
                if ($anchorVer) { $diag += ('Anchor Solution : ' + $anchorVer + '  (Dataverse record only, not used for any decision here)') }

                if (-not $optDoApply) {
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " (" + $depType + ")") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt -Note 'inventory only'
                    continue
                }

                $eligible = $true
                if ((Get-Count $foDepTypesL) -gt 0) {
                    $eligible = $false
                    foreach ($dt in $foDepTypesL) { if ($depType -ieq ([string]$dt)) { $eligible = $true; break } }
                }
                if (-not $eligible) {
                    $foNotEligible++
                    $reason = if ($depType -like 'LCS*') { 'LCS managed' } else { 'deployment type not eligible' }
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " (" + $depType + ") - skipped, " + $reason + ".") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note ('version apply skipped (' + $depType + ')')
                    continue
                }

                $verUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf 'finopsversions'
                $vr = Invoke-PpRest -Method 'GET' -RequestUri $verUri -Headers $ppHeaders
                if ($vr.Transport -or $vr.Status -lt 200 -or $vr.Status -ge 300) {
                    $codeText = Get-ApiErrorCode -Response $vr
                    if (-not $vr.Transport -and $codeText -eq 'RouteNotFound') {
                        $foRouteMissing++
                        Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                            -Headline ($curVer + " (" + $depType + ") - versions route unavailable (RouteNotFound).") `
                            -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt -Note 'versions: RouteNotFound'
                    }
                    else {
                        $foFailed++
                        Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                            -Headline ($curVer + " (" + $depType + ") - versions lookup failed: " + (Format-RestFailure -Response $vr)) `
                            -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                            -Note ('versions: ' + $(if ($vr.Transport) { 'transport failure' } else { 'HTTP ' + $vr.Status }))
                    }
                    continue
                }

                $available = @(ConvertTo-FinOpsVersionList -Json $vr.Json)
                if ((Get-Count $available) -eq 0) {
                    $foNoVersions++
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " (" + $depType + ") - no versions listed.") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt -Note 'no versions returned'
                    continue
                }

                $availLabel = (($available | ForEach-Object { $_.Version + ' [Status: ' + $_.ReleaseStage + ']' }) -join ', ')
                $diag += ('New version available : ' + $availLabel)

                # Scope filter, matched directly against Microsoft's own
                # releaseStage - no derived classification of any kind.
                $scoped = $available
                if ($optFinOpsScope -eq 'QualityUpdate') {
                    $scoped = @($available | Where-Object { $_.ReleaseStage -ieq 'QualityUpdate' })
                }
                elseif ($optFinOpsScope -eq 'VersionUpdate') {
                    $scoped = @($available | Where-Object { $_.ReleaseStage -ine 'QualityUpdate' })
                }
                if ($optFinOpsScope -ne 'Any' -and (Get-Count $scoped) -eq 0) {
                    $foScopeFiltered++
                    $scopeLabel = Get-FinOpsScopeLabel -Scope $optFinOpsScope
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " (" + $depType + ") - no " + $scopeLabel + " version available. New version available: " + $availLabel) `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note ('no ' + $scopeLabel + ' version available')
                    continue
                }

                $target = $optFinOpsTarget
                $targetStage = 'Unknown'
                if ($target -eq '') {
                    $target = Select-HighestVersion -Versions ($scoped | ForEach-Object { $_.Version })
                    $match = $available | Where-Object { $_.Version -eq $target } | Select-Object -First 1
                    if ($match) { $targetStage = $match.ReleaseStage }
                }
                else {
                    $match = $available | Where-Object { $_.Version -eq $target } | Select-Object -First 1
                    if (-not $match) {
                        $foFailed++
                        Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                            -Headline ($curVer + " -> requested '" + $target + "' is not in the available list.") `
                            -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt -Note 'target not available'
                        continue
                    }
                    $targetStage = $match.ReleaseStage
                    if ($optFinOpsScope -ne 'Any' -and ($scoped.Version -notcontains $target)) {
                        $foScopeFiltered++
                        $scopeLabel = Get-FinOpsScopeLabel -Scope $optFinOpsScope
                        Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                            -Headline ($curVer + " -> requested '" + $target + "' [Status: " + $targetStage + "] is not a " + $scopeLabel + ".") `
                            -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                            -Note ('target exists but is ' + $targetStage + ', not ' + $optFinOpsScope)
                        continue
                    }
                }

                if ($optPlanOnly) {
                    $foApplied++
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " -> " + [string]$target + " [Status: " + $targetStage + "] - [WhatIf] would apply.") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note ('would apply ' + [string]$target + ' [' + $targetStage + ']')
                    continue
                }

                $applyUri = New-FinOpsUri -EnvironmentId $envIdFo -Leaf ('finopsversions/' + [string]$target + '/apply')
                $ar = Invoke-PpRest -Method 'POST' -RequestUri $applyUri -Headers $ppHeaders
                if (-not $ar.Transport -and $ar.Status -eq 202) {
                    $foApplied++
                    $opId = ''
                    if ($ar.Json -and $ar.Json.operationId) { $opId = [string]$ar.Json.operationId }
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " -> " + [string]$target + " [Status: " + $targetStage + "] - accepted, applying (op " + $opId + ").") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note ('applying ' + [string]$target + ' [' + $targetStage + ']')
                }
                elseif (-not $ar.Transport -and $ar.Status -eq 204) {
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " -> " + [string]$target + " - platform confirms already at or above (204).") `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note 'up to date (204)'
                }
                else {
                    $foFailed++
                    Complete-FoEnvironment -EnvName $envNameFo -ShowDiag $optDumpDiag -Diag $diag `
                        -Headline ($curVer + " -> " + [string]$target + " - apply failed: " + (Format-RestFailure -Response $ar)) `
                        -Application $curVer -Platform $platVer -Deployment $depType -AOS $aosInt `
                        -Note ('apply: ' + $(if ($ar.Transport) { 'transport failure' } else { 'HTTP ' + $ar.Status }))
                }
            }

            if ((Get-Count $foInventory) -gt 0) {
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
if ($totalAdminModeEnvs -gt 0) {
    Write-Host "Environments in Admin Mode:     $totalAdminModeEnvs"
    Write-Host "App installs skipped (Admin Mode): $totalAdminModeSkipped"
}
Write-Host "Failures/warnings:              $totalFailed"
Write-Host "F&O environments detected:      $(Get-Count $finOpsDetected)"

if ($optDoFinOps -and (Get-Count $finOpsDetected) -gt 0) {
    Write-Host "F&O environments inspected:     $foChecked"
    if ($foPropsFailed -gt 0)  { Write-Host "F&O properties unavailable:     $foPropsFailed" }
    if ($optDoApply) {
        Write-Host "F&O versions applied/planned:   $foApplied"
        if ($foNotEligible   -gt 0) { Write-Host "  skipped (deployment type):   $foNotEligible" }
        if ($foRouteMissing  -gt 0) { Write-Host "  skipped (route unavailable): $foRouteMissing" }
        if ($foNoVersions    -gt 0) { Write-Host "  skipped (no versions listed):$foNoVersions" }
        if ($foScopeFiltered -gt 0) { Write-Host "  skipped (no scope match):    $foScopeFiltered" }
        if ($foFailed        -gt 0) { Write-Host "  failed:                      $foFailed" }
    }
    else {
        Write-Host "Version apply:                  off (set finOpsApplyVersion = true)"
    }
}
else {
    Write-Host "F&O phase:                      skipped (PowerShell 7 required)"
}

if ((Get-Count $manualList) -gt 0) {
    Write-Host ''
    Write-Host '##[group]Manual install required (use Power Platform Admin Center)'
    $manualList | Sort-Object Environment, App | Format-Table Environment, App, Installed, Available -AutoSize | Out-String | Write-Host
    Write-Host '##[endgroup]'
}

if ((Get-Count $adminModeList) -gt 0) {
    Write-Host ''
    Write-Host '##[group]Environments in Admin Mode'
    $adminModeList | Sort-Object Environment | Format-Table Environment, Id, AppsSkipped -AutoSize | Out-String | Write-Host
    Write-Host '##[endgroup]'
}

Write-Host ''
Write-Host 'All environments processed'
$global:LASTEXITCODE = 0
exit 0
