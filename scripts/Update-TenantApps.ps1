<#
.SYNOPSIS
    Updates all Dynamics 365 first-party (Dataverse) apps across every
    environment on a tenant.

.DESCRIPTION
    Authenticates as a service principal using the client credentials flow,
    discovers every environment on the tenant through the BAP admin API,
    reads each environment's available application packages from the Power
    Platform App Management API, reads the installed versions from Dataverse
    managed solutions, and installs updates where a strictly newer version
    exists. Optionally retries previously failed installs, and can skip apps
    that require the PPAC Custom Install Experience.

    CONFIGURATION MODEL
      Only three inputs are required: ClientId, ClientSecret, TenantId.
      Everything else has a sensible built-in default. Any default can be
      overridden WITHOUT editing this script - just add a variable with the
      matching name to the 'D365-TenantAppUpdater' variable group and the
      pipeline passes it in. If the variable is absent, the default is used.

      Overridable settings and their defaults:
        authority                -> https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
        bapApiRoot               -> https://api.bap.microsoft.com
        bapApiVersion            -> 2026-06-01
        powerPlatformScope       -> https://api.powerplatform.com/.default
        ppApiRoot                -> https://api.powerplatform.com
        appManagementApiVersion  -> 2026-05-01-preview
        pollIntervalSec          -> 20
        pollTimeoutMin           -> 60
        dumpDiagnostics          -> true
        retryFailedInstalls      -> true
        whatIf                   -> false
        usePacFallback           -> false
        environmentFilter        -> (blank = all)
        environmentExclude       -> (blank = none)
        appExclude               -> msdyn_FinanceAndOperationsProvisioningApp

    Community project. Not an official Microsoft tool. Test in non-production first.

.NOTES
    Author : Laze Janev
    License: MIT
    Repo   : https://github.com/lazejanev/d365-tenant-app-updater
#>

[CmdletBinding()]
param(
    # --- Required: credentials ---
    [Parameter(Mandatory = $true)] [string] $ClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecret,
    [Parameter(Mandatory = $true)] [string] $TenantId,

    # --- Optional: endpoints and API config (blank => use built-in default) ---
    [Parameter()] [string] $Authority               = '',
    [Parameter()] [string] $BapApiRoot              = '',
    [Parameter()] [string] $BapApiVersion           = '',
    [Parameter()] [string] $PowerPlatformScope      = '',
    [Parameter()] [string] $PpApiRoot               = '',
    [Parameter()] [string] $AppManagementApiVersion = '',
    [Parameter()] [string] $PollIntervalSec         = '',
    [Parameter()] [string] $PollTimeoutMin          = '',

    # --- Optional: behavior (blank => use built-in default) ---
    [Parameter()] [string] $DumpDiagnostics     = '',
    [Parameter()] [string] $RetryFailedInstalls = '',
    [Parameter()] [string] $WhatIf              = '',
    [Parameter()] [string] $EnvironmentFilter   = '',
    [Parameter()] [string] $EnvironmentExclude  = '',
    [Parameter()] [string] $AppExclude          = '',
    [Parameter()] [string] $UsePacFallback      = ''
)

# StrictMode intentionally off; counts are guarded explicitly via Get-Count.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# Built-in defaults. Change here only if you want a different baseline;
# per-run overrides come from the variable group / pipeline, not from here.
# ---------------------------------------------------------------------
$Defaults = @{
    BapApiRoot              = 'https://api.bap.microsoft.com'
    BapApiVersion           = '2026-06-01'
    PowerPlatformScope      = 'https://api.powerplatform.com/.default'
    PpApiRoot               = 'https://api.powerplatform.com'
    AppManagementApiVersion = '2026-05-01-preview'
    PollIntervalSec         = '20'
    PollTimeoutMin          = '60'
    DumpDiagnostics         = 'true'
    RetryFailedInstalls     = 'true'
    WhatIf                  = 'false'
    EnvironmentFilter       = ''
    EnvironmentExclude      = ''
    AppExclude              = 'msdyn_FinanceAndOperationsProvisioningApp'
    UsePacFallback          = 'false'
}

# Return the provided value unless it is blank or an unexpanded Azure DevOps
# macro like '$(bapApiVersion)' (which happens when the variable is not
# defined in the group). In those cases the value is treated as "not set".
function Get-OrDefault {
    param([AllowEmptyString()] [string] $Value, [AllowEmptyString()] [string] $Default)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    if ($Value -match '^\s*\$\(.*\)\s*$') { return $Default }
    if ($Value -ieq '(empty)' -or $Value -ieq '(none)' -or $Value -ieq '(all)') { return $Default }
    return $Value
}

# Resolve a setting from: the explicit parameter, else the matching
# environment variable (how the pipeline passes optional overrides), else
# the built-in default. Unexpanded '$(name)' macros are treated as not set.
function Resolve-Setting {
    param(
        [AllowEmptyString()] [string] $ParamValue,
        [string]             $EnvName,
        [AllowEmptyString()] [string] $Default
    )
    $v = $ParamValue
    $vClean = Get-OrDefault $v '__unset__'
    if ($vClean -eq '__unset__') {
        $v = [Environment]::GetEnvironmentVariable($EnvName)
    }
    return Get-OrDefault $v $Default
}

$Authority               = Resolve-Setting $Authority               'Authority'               "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$BapApiRoot              = Resolve-Setting $BapApiRoot              'BapApiRoot'              $Defaults.BapApiRoot
$BapApiVersion           = Resolve-Setting $BapApiVersion           'BapApiVersion'           $Defaults.BapApiVersion
$PowerPlatformScope      = Resolve-Setting $PowerPlatformScope      'PowerPlatformScope'      $Defaults.PowerPlatformScope
$PpApiRoot               = Resolve-Setting $PpApiRoot               'PpApiRoot'               $Defaults.PpApiRoot
$AppManagementApiVersion = Resolve-Setting $AppManagementApiVersion 'AppManagementApiVersion' $Defaults.AppManagementApiVersion
$PollIntervalSec         = [int](Resolve-Setting $PollIntervalSec   'PollIntervalSec'         $Defaults.PollIntervalSec)
$PollTimeoutMin          = [int](Resolve-Setting $PollTimeoutMin    'PollTimeoutMin'          $Defaults.PollTimeoutMin)

$dumpDiagRaw = Resolve-Setting $DumpDiagnostics     'DumpDiagnostics'     $Defaults.DumpDiagnostics
$retryRaw    = Resolve-Setting $RetryFailedInstalls 'RetryFailedInstalls' $Defaults.RetryFailedInstalls
$whatIfRaw   = Resolve-Setting $WhatIf              'WhatIf'              $Defaults.WhatIf
$usePacRaw   = Resolve-Setting $UsePacFallback      'UsePacFallback'      $Defaults.UsePacFallback
$envFilter   = Resolve-Setting $EnvironmentFilter   'EnvironmentFilter'   $Defaults.EnvironmentFilter
$envExcl     = Resolve-Setting $EnvironmentExclude  'EnvironmentExclude'  $Defaults.EnvironmentExclude
$appExclIn   = Resolve-Setting $AppExclude          'AppExclude'          $Defaults.AppExclude

# ---------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------
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
    $items = $Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    return ,([string[]]@($items))
}

function Format-Scope {
    param([AllowEmptyString()] [string] $Raw, [string] $EmptyLabel)
    $list = Split-List $Raw
    if ((Get-Count $list) -eq 0) { return $EmptyLabel }
    return ($list -join ', ')
}

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "===== $Text ====="
}

$dumpDiag = ConvertTo-Bool $dumpDiagRaw
$retry    = ConvertTo-Bool $retryRaw
$planOnly = ConvertTo-Bool $whatIfRaw
$usePac   = ConvertTo-Bool $usePacRaw

$Config = [ordered]@{
    Authority               = $Authority
    BapApiRoot              = $BapApiRoot.TrimEnd('/')
    BapScope                = "$($BapApiRoot.TrimEnd('/'))/.default"
    BapApiVersion           = $BapApiVersion
    PowerPlatformScope      = $PowerPlatformScope
    PpApiRoot               = $PpApiRoot.TrimEnd('/')
    AppManagementApiVersion = $AppManagementApiVersion
    PollIntervalSec         = $PollIntervalSec
    PollTimeoutMin          = $PollTimeoutMin
}

# ---------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------
function Get-Token {
    param([string] $Scope)
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = 'client_credentials'
        scope         = $Scope
    }
    $r = Invoke-RestMethod -Method POST -Uri $Config.Authority -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
    if (-not $r.access_token) { throw "No access_token for scope '$Scope'." }
    return $r.access_token
}

# ---------------------------------------------------------------------
# URL builder for the Power Platform App Management API
# ---------------------------------------------------------------------
function New-PpUrl {
    param([Parameter(Mandatory)] [string] $Path, [hashtable] $Query = @{})
    $b = [System.UriBuilder]::new("$($Config.PpApiRoot)$Path")
    $pairs = New-Object System.Collections.Generic.List[string]
    foreach ($k in $Query.Keys) {
        $pairs.Add("$([System.Uri]::EscapeDataString([string]$k))=$([System.Uri]::EscapeDataString([string]$Query[$k]))")
    }
    $pairs.Add("api-version=$([System.Uri]::EscapeDataString($Config.AppManagementApiVersion))")
    $b.Query = [string]::Join('&', $pairs)
    return $b.Uri.AbsoluteUri
}

# ---------------------------------------------------------------------
# Installed versions: read managed-solution versions from Dataverse.
# ---------------------------------------------------------------------
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

# True only when $Available is strictly NEWER than $Installed (never downgrade).
function Test-UpdateAvailable {
    param([string] $Available, [string] $Installed)
    $a = $null; $i = $null
    if ([System.Version]::TryParse($Available, [ref]$a) -and [System.Version]::TryParse($Installed, [ref]$i)) {
        return ($a -gt $i)
    }
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
    param($Pkg, [string[]] $List)
    if ((Get-Count $List) -eq 0) { return $false }
    foreach ($item in $List) {
        foreach ($key in @($Pkg.uniqueName, $Pkg.localizedName, $Pkg.applicationName, $Pkg.applicationId)) {
            if ($key -and ([string]$key) -ieq $item) { return $true }
        }
    }
    return $false
}

function Test-EnvInList {
    param($EnvObj, [string[]] $List)
    if ((Get-Count $List) -eq 0) { return $false }
    foreach ($item in $List) {
        if ($EnvObj.DisplayName -and $EnvObj.DisplayName -ieq $item) { return $true }
        if ($EnvObj.Id          -and $EnvObj.Id          -ieq $item) { return $true }
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
    if ($resp.lastOperation.operationId) {
        Write-Host "  Operation triggered: $($resp.lastOperation.operationId)"
        return $true
    }
    Write-Host '  Install accepted (no operation id returned).'
    return $false
}

# ---------------------------------------------------------------------
# PAC CLI fallback (best effort, opt-in)
# ---------------------------------------------------------------------
$script:PacReady = $false
function Initialize-Pac {
    if ($script:PacReady) { return $true }
    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) { Write-Warning 'PAC fallback requested but the pac CLI is not installed on the agent. Skipping fallback.'; return $false }
    try {
        pac auth create --name d365updater --applicationId $ClientId --clientSecret $ClientSecret --tenant $TenantId | Out-Null
        $script:PacReady = $true
        Write-Host '  PAC CLI authenticated with service principal.'
        return $true
    } catch { Write-Warning "  PAC auth create failed. $($_.Exception.Message)"; return $false }
}
function Invoke-PacInstall {
    param([string] $EnvironmentId, $Pkg)
    if (-not (Initialize-Pac)) { return $false }
    try {
        pac application install --environment-id $EnvironmentId --application-name $Pkg.uniqueName
        if ($LASTEXITCODE -eq 0) { Write-Host "  [PAC] Update succeeded for '$($Pkg.uniqueName)'."; return $true }
        Write-Warning "  [PAC] Exit code $LASTEXITCODE for '$($Pkg.uniqueName)'."; return $false
    } catch { Write-Warning "  [PAC] Install failed for '$($Pkg.uniqueName)'. $($_.Exception.Message)"; return $false }
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
$filterList  = Split-List $envFilter
$excludeList = Split-List $envExcl
$appExclude  = Split-List $appExclIn

# Explicit overrides for apps whose package unique name does not match their
# Dataverse solution name. Key = app uniqueName (lower); Value = solution
# uniquename OR friendlyname (lower). Fill from the diagnostic output if needed.
$appSolutionAlias = @{}

Write-Section 'Effective settings'
Write-Host ("  BapApiVersion           : {0}" -f $Config.BapApiVersion)
Write-Host ("  AppManagementApiVersion : {0}" -f $Config.AppManagementApiVersion)
Write-Host ("  DumpDiagnostics         : {0}" -f $dumpDiag)
Write-Host ("  RetryFailedInstalls     : {0}" -f $retry)
Write-Host ("  WhatIf (plan only)      : {0}" -f $planOnly)
Write-Host ("  UsePacFallback          : {0}" -f $usePac)
Write-Host ("  EnvironmentFilter       : {0}" -f (Format-Scope -Raw $envFilter -EmptyLabel '(all)'))
Write-Host ("  EnvironmentExclude      : {0}" -f (Format-Scope -Raw $envExcl   -EmptyLabel '(none)'))
Write-Host ("  AppExclude              : {0}" -f (Format-Scope -Raw $appExclIn -EmptyLabel '(none)'))

Write-Section 'Authenticating'
$ppToken  = Get-Token $Config.PowerPlatformScope
$bapToken = Get-Token $Config.BapScope
Write-Host 'Acquired Power Platform and BAP tokens'

$ppHeaders  = @{ Authorization = "Bearer $ppToken";  Accept = 'application/json'; 'Content-Type' = 'application/json' }
$bapHeaders = @{ Authorization = "Bearer $bapToken"; Accept = 'application/json' }

Write-Section 'Listing environments'
$envUri = "$($Config.BapApiRoot)/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?`$expand=properties&api-version=$($Config.BapApiVersion)"
$envResp = Invoke-RestMethod -Method GET -Uri $envUri -Headers $bapHeaders -ErrorAction Stop

$environments = @(
    foreach ($e in @($envResp.value)) {
        $instanceUrl = $e.properties.linkedEnvironmentMetadata.instanceUrl
        if (-not $instanceUrl) { continue }   # skip non-Dataverse environments
        [pscustomobject]@{
            Id          = $e.name
            DisplayName = if ($e.properties.displayName) { $e.properties.displayName } else { $e.name }
            InstanceUrl = $instanceUrl
        }
    }
)
Write-Host "Found $(Get-Count $environments) Dataverse environment(s)"

$environments = @(
    foreach ($envObj in $environments) {
        $inFilter  = ((Get-Count $filterList) -eq 0) -or (Test-EnvInList -EnvObj $envObj -List $filterList)
        $inExclude = Test-EnvInList -EnvObj $envObj -List $excludeList
        if ($inExclude) { Write-Host "  Skipping (excluded): $($envObj.DisplayName)"; continue }
        if (-not $inFilter) { continue }
        $envObj
    }
)
Write-Host "Processing $(Get-Count $environments) environment(s) after filter and exclude."

$knownUpdateHints = @('Customer Service Analytics','Customer Service Intelligence','Agent Productivity','appprofilemanager','AppProfileManager')

$totalEnvironments = 0; $totalUpdates = 0; $totalRetries = 0; $totalOperations = 0
$totalUpToDate = 0; $totalNoMatch = 0; $totalFailed = 0; $totalManual = 0; $totalExcluded = 0
$solDumped = $false
$manualList = New-Object System.Collections.Generic.List[object]

foreach ($envObj in $environments) {
    $envId = $envObj.Id; $envName = $envObj.DisplayName; $instanceUrl = $envObj.InstanceUrl
    $totalEnvironments++

    Write-Host ''
    Write-Host '##[section]============================================================'
    Write-Host "##[section]ENVIRONMENT: $envName"
    Write-Host "##[section]ID: $envId"
    Write-Host '##[section]============================================================'

    # AVAILABLE versions (Power Platform App Management API)
    try {
        $pkgUrl = New-PpUrl -Path "/appmanagement/environments/$envId/applicationPackages" -Query @{ appInstallState = 'All'; lcid = '1033' }
        $available = @((Invoke-RestMethod -Method GET -Uri $pkgUrl -Headers $ppHeaders -ErrorAction Stop).value)
    }
    catch { $totalFailed++; Write-Host "##[warning]Failed to list available packages for '$envName': $_"; continue }

    # INSTALLED versions (Dataverse managed solutions; needs System Admin app-user)
    try {
        $hints = if ($dumpDiag -and -not $solDumped) { @('crm','hub','sales','insight','productivity','globalization','quality','channel','customerservice','outlook') } else { @() }
        $solMap = Get-SolutionVersionMap -InstanceUrl $instanceUrl -DumpHints $hints
        $solDumped = $true
    }
    catch {
        $totalFailed++
        Write-Host "##[warning]Failed to read Dataverse solution versions for '$envName': $_"
        Write-Host '##[warning]Skipping this environment (no installed data => nothing installed blindly).'
        continue
    }

    $candidates = @(
        $available | Where-Object {
            $_.uniqueName -and ( $_.state -eq 'Installed' -or ($retry -and $_.state -eq 'InstallFailed') )
        }
    )
    Write-Host "Installed apps evaluated: $(Get-Count $candidates)  (managed solutions read: $($solMap.Count))"

    if ($dumpDiag) {
        Write-Host '##[group]DIAGNOSTIC: installed (solution) vs available for known apps'
        foreach ($c in $candidates) {
            $isKnown = $false
            foreach ($h in $knownUpdateHints) { if ("$($c.localizedName)" -like "*$h*" -or "$($c.uniqueName)" -like "*$h*") { $isKnown = $true } }
            if ($isKnown) {
                $iv = Resolve-InstalledVersion $c $solMap $appSolutionAlias
                Write-Host (" - {0} [{1}]  installed: {2}  available: {3}" -f $c.localizedName, $c.uniqueName, $(if($iv){$iv}else{'<no matching solution>'}), $c.version)
            }
        }
        Write-Host '##[endgroup]'
    }

    $envUpdates = 0; $envRetries = 0; $envUpToDate = 0; $envNoMatch = 0; $envExcluded = 0; $noMatchNames = @()

    foreach ($pkg in $candidates) {
        $name  = if ($pkg.localizedName) { $pkg.localizedName } else { $pkg.uniqueName }
        $avail = [string]$pkg.version

        if (Test-AppExcluded -Pkg $pkg -List $appExclude) {
            $envExcluded++; $totalExcluded++
            if ($dumpDiag) { Write-Host "  Skipping (app excluded): $name" }
            continue
        }

        if ($pkg.state -eq 'InstallFailed') {
            $envRetries++; $totalRetries++
            Write-Host ''
            Write-Host "Retrying failed installation: $name  (target version: $avail)"
            if ($planOnly) { Write-Host '  [WhatIf] would retry install.'; continue }
            try { if (Invoke-AppInstall -Pkg $pkg -EnvId $envId -Headers $ppHeaders) { $totalOperations++ } }
            catch {
                $errText = $_.Exception.Message
                if (Test-CustomInstallExperience -Message $errText) {
                    $handled = $false
                    if ($usePac) { $handled = Invoke-PacInstall -EnvironmentId $envId -Pkg $pkg }
                    if (-not $handled) { $totalManual++; $manualList.Add([pscustomobject]@{ Environment=$envName; App=$name; Installed=''; Available=$avail }); Write-Host "  '$name' requires manual install via PPAC." }
                } else { $totalFailed++; Write-Host "##[warning]Failed to retry '$name': $_" }
            }
            continue
        }

        $inst = Resolve-InstalledVersion $pkg $solMap $appSolutionAlias
        if (-not $inst) { $envNoMatch++; $totalNoMatch++; $noMatchNames += ("{0} [{1}] avail {2}" -f $name, $pkg.uniqueName, $avail); continue }
        if (-not (Test-UpdateAvailable -Available $avail -Installed $inst)) { $envUpToDate++; $totalUpToDate++; continue }

        $envUpdates++; $totalUpdates++
        Write-Host ''
        Write-Host "Update available: $name  installed: $inst  available: $avail"
        if ($planOnly) { Write-Host "  [WhatIf] would update to $avail."; continue }
        try { if (Invoke-AppInstall -Pkg $pkg -EnvId $envId -Headers $ppHeaders) { $totalOperations++ } }
        catch {
            $errText = $_.Exception.Message
            if (Test-CustomInstallExperience -Message $errText) {
                $handled = $false
                if ($usePac) { Write-Host "  '$name' needs a custom install. Trying PAC CLI fallback..."; $handled = Invoke-PacInstall -EnvironmentId $envId -Pkg $pkg }
                if ($handled) { Write-Host "  Updated '$name' via PAC CLI." }
                else { $totalManual++; $manualList.Add([pscustomobject]@{ Environment=$envName; App=$name; Installed=$inst; Available=$avail }); Write-Host "  '$name' requires manual install via Power Platform Admin Center. Consider adding it to AppExclude." }
            } else { $totalFailed++; Write-Host "##[warning]Failed to update '$name': $_" }
        }
    }

    if ($dumpDiag -and (Get-Count $noMatchNames) -gt 0) {
        Write-Host '##[group]Apps with no matching managed solution (not evaluated for update)'
        $noMatchNames | ForEach-Object { Write-Host " - $_" }
        Write-Host '##[endgroup]'
    }
    Write-Host ''
    Write-Host "Environment summary -> updates: $envUpdates | failed-retries: $envRetries | up-to-date: $envUpToDate | no solution match: $envNoMatch | app-excluded: $envExcluded"
}

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

if ((Get-Count $manualList) -gt 0) {
    Write-Host ''
    Write-Host '##[group]Manual install required (use Power Platform Admin Center)'
    $manualList | Sort-Object Environment, App | Format-Table Environment, App, Installed, Available -AutoSize | Out-String | Write-Host
    Write-Host 'These apps use a Custom Install Experience and cannot be installed by the API. Add them to AppExclude to silence future runs.'
    Write-Host '##[endgroup]'
}

Write-Host ''
Write-Host 'All environments processed'
