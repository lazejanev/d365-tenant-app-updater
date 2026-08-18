<#
.SYNOPSIS
    Updates all Dynamics 365 first-party apps across every environment on a tenant.

.DESCRIPTION
    Authenticates as a service principal using the client credentials flow,
    discovers every environment on the tenant through the BAP admin API,
    compares installed versus available app versions per environment, and
    installs the updates that are needed. Retries previously failed installs
    (on by default) and prints an installed versus available diagnostic.

    Environment scoping:
      - EnvironmentFilter  : allow-list. If set, ONLY these environments are
                             processed. Blank means all environments.
      - EnvironmentExclude : deny-list. These environments are ALWAYS skipped,
                             even if they match the filter. Use it to protect
                             production or any environment you never want touched.

    App scoping:
      - AppExclude         : deny-list of application names or ids that are
                             ALWAYS skipped on every environment. Use it for
                             apps that cannot be installed by this API (apps
                             that require the PPAC Custom Install Experience,
                             such as the F&O Provisioning App).

    Custom Install Experience apps:
      Some first-party apps use a guided Single Page Application install in the
      Power Platform Admin Center. The BAP install API rejects these with a
      400 and a "not supported by this API" message. This script:
        1. Skips any app listed in AppExclude up front.
        2. Detects that specific 400 and classifies the app as
           'manual-required' instead of 'failed', so retry does not hammer it.
        3. Optionally (UsePacFallback) attempts 'pac application install' as a
           best-effort fallback. Note: the PAC CLI calls the same programmability
           API family, so it may still be blocked for true SPA-install apps.

    DESIGN RULE: this script hardcodes nothing. Every value is passed in from
    the pipeline, which sources them from the Library variable group
    'D365-TenantAppUpdater'.

    Runtime override pattern: each behavior flag accepts a value or the
    sentinel 'fromLibrary'. When 'fromLibrary' is passed, the matching
    Default* parameter (the variable-group value) is used instead.

    This is a community project and is not an official Microsoft tool.
    Test it against a non-production tenant before using it in production.

.NOTES
    Author : Laze Janev
    License: MIT
    Repo   : https://github.com/lazejanev/d365-tenant-app-updater
#>

[CmdletBinding()]
param(
    # --- Credentials (from the variable group) ---
    [Parameter(Mandatory = $true)] [string] $ClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecret,
    [Parameter(Mandatory = $true)] [string] $TenantId,

    # --- Endpoints and API configuration (from the variable group) ---
    [Parameter(Mandatory = $true)] [string] $Authority,
    [Parameter(Mandatory = $true)] [string] $BapResource,
    [Parameter(Mandatory = $true)] [string] $BapApiRoot,
    [Parameter(Mandatory = $true)] [string] $BapApiVersion,
    [Parameter(Mandatory = $true)] [string] $PowerPlatformScope,
    [Parameter(Mandatory = $true)] [int]    $PollIntervalSec,
    [Parameter(Mandatory = $true)] [int]    $PollTimeoutMin,

    # --- Behavior flags (runtime override or 'fromLibrary') ---
    [Parameter()] [string] $DumpDiagnostics     = 'fromLibrary',
    [Parameter()] [string] $RetryFailedInstalls = 'fromLibrary',
    [Parameter()] [string] $WhatIf              = 'fromLibrary',
    [Parameter()] [string] $EnvironmentFilter   = 'fromLibrary',
    [Parameter()] [string] $EnvironmentExclude  = 'fromLibrary',
    [Parameter()] [string] $AppExclude          = 'fromLibrary',
    [Parameter()] [string] $UsePacFallback      = 'fromLibrary',

    # --- Behavior defaults (from the variable group) ---
    [Parameter()] [string] $DefaultDumpDiagnostics     = 'true',
    [Parameter()] [string] $DefaultRetryFailedInstalls = 'true',
    [Parameter()] [string] $DefaultWhatIf              = 'false',
    [Parameter()] [string] $DefaultEnvironmentFilter   = '',
    [Parameter()] [string] $DefaultEnvironmentExclude  = '',
    [Parameter()] [string] $DefaultAppExclude          = 'msdyn_FinanceAndOperationsProvisioningApp',
    [Parameter()] [string] $DefaultUsePacFallback      = 'false'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# Resolve runtime overrides against the library defaults
# ---------------------------------------------------------------------
function Resolve-Value {
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Override,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Default
    )
    if ([string]::IsNullOrWhiteSpace($Override) -or $Override -ieq 'fromLibrary') {
        return $Default
    }
    return $Override
}

function ConvertTo-Bool {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    return @('true', '1', 'yes', 'y', 'on') -contains ($Text.Trim().ToLowerInvariant())
}

$dumpDiag     = ConvertTo-Bool (Resolve-Value -Override $DumpDiagnostics     -Default $DefaultDumpDiagnostics)
$retry        = ConvertTo-Bool (Resolve-Value -Override $RetryFailedInstalls -Default $DefaultRetryFailedInstalls)
$planOnly     = ConvertTo-Bool (Resolve-Value -Override $WhatIf              -Default $DefaultWhatIf)
$usePac       = ConvertTo-Bool (Resolve-Value -Override $UsePacFallback      -Default $DefaultUsePacFallback)
$envFilter    = Resolve-Value -Override $EnvironmentFilter  -Default $DefaultEnvironmentFilter
$envExclude   = Resolve-Value -Override $EnvironmentExclude -Default $DefaultEnvironmentExclude
$appExcludeIn = Resolve-Value -Override $AppExclude         -Default $DefaultAppExclude

# ---------------------------------------------------------------------
# Config object, built entirely from passed-in parameters
# ---------------------------------------------------------------------
$Config = [ordered]@{
    Authority          = $Authority
    BapResource        = $BapResource
    BapApiRoot         = $BapApiRoot
    BapApiVersion      = $BapApiVersion
    PowerPlatformScope = $PowerPlatformScope
    PollIntervalSec    = $PollIntervalSec
    PollTimeoutMin     = $PollTimeoutMin
}

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------
function Get-Token {
    param([Parameter(Mandatory)] [string] $Scope)

    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = 'client_credentials'
        scope         = $Scope
    }

    try {
        $resp = Invoke-RestMethod -Method POST -Uri $Config.Authority `
            -ContentType 'application/x-www-form-urlencoded' -Body $body
        return $resp.access_token
    }
    catch {
        throw "Failed to acquire token for scope '$Scope'. $($_.Exception.Message)"
    }
}

function Invoke-Bap {
    param(
        [Parameter(Mandatory)] [string] $Method,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter()]          [object] $Body
    )

    $uri = "$($Config.BapApiRoot)$Path"
    if ($uri -notmatch 'api-version=') {
        $sep = if ($uri -match '\?') { '&' } else { '?' }
        $uri = "$uri$sep`api-version=$($Config.BapApiVersion)"
    }

    $headers = @{
        Authorization = "Bearer $Token"
        Accept        = 'application/json'
    }

    $params = @{ Method = $Method; Uri = $uri; Headers = $headers }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10)
        $params['ContentType'] = 'application/json'
    }

    return Invoke-RestMethod @params
}

function Split-List {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return $Text.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

function Test-InList {
    param(
        [Parameter(Mandatory)] [object]   $Environment,
        [Parameter(Mandatory)] [string[]] $List
    )
    if ($List.Count -eq 0) { return $false }

    $name = $Environment.properties.displayName
    $id   = $Environment.name

    foreach ($item in $List) {
        if ($name -and $name -ieq $item) { return $true }
        if ($id   -and $id   -ieq $item) { return $true }
    }
    return $false
}

function Test-AppInList {
    param(
        [Parameter(Mandatory)] [object]   $App,
        [Parameter(Mandatory)] [string[]] $List
    )
    if ($List.Count -eq 0) { return $false }
    foreach ($item in $List) {
        if ($App.name  -and $App.name  -ieq $item) { return $true }
        if ($App.appId -and $App.appId -ieq $item) { return $true }
    }
    return $false
}

# Recognize the "Custom Install Experience" / SPA restriction from an error.
function Test-CustomInstallExperience {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $false }
    $m = $Message.ToLowerInvariant()
    return ($m -match 'custom install experience') `
        -or ($m -match 'single page application') `
        -or ($m -match 'not supported by this api')
}

function Get-ErrorText {
    param([Parameter(Mandatory)] $ErrorRecord)
    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp -and $resp.GetResponseStream) {
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $text = $reader.ReadToEnd()
            if ($text) { return $text }
        }
    } catch { }
    return $ErrorRecord.Exception.Message
}

function Write-Section {
    param([Parameter(Mandatory)] [string] $Text)
    Write-Host ''
    Write-Host "===== $Text ====="
}

# ---------------------------------------------------------------------
# PAC CLI fallback (best effort, opt-in)
# ---------------------------------------------------------------------
$script:PacReady = $false

function Initialize-Pac {
    if ($script:PacReady) { return $true }

    $pac = Get-Command pac -ErrorAction SilentlyContinue
    if (-not $pac) {
        Write-Warning 'PAC fallback requested but the pac CLI is not installed on the agent. Skipping fallback. See docs/setup.md for the install step.'
        return $false
    }

    try {
        # Service principal auth. Name the profile so we can reuse it.
        pac auth create --name d365updater `
            --applicationId $ClientId `
            --clientSecret  $ClientSecret `
            --tenant        $TenantId | Out-Null
        $script:PacReady = $true
        Write-Host '  PAC CLI authenticated with service principal.'
        return $true
    }
    catch {
        Write-Warning "  PAC auth create failed. $($_.Exception.Message)"
        return $false
    }
}

function Invoke-PacInstall {
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,
        [Parameter(Mandatory)] [object] $App
    )

    if (-not (Initialize-Pac)) { return $false }

    try {
        Write-Host "  [PAC] pac application install --environment-id $EnvironmentId --application-name $($App.name)"
        pac application install --environment-id $EnvironmentId --application-name $App.name
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [PAC] Update succeeded for '$($App.name)'."
            return $true
        }
        Write-Warning "  [PAC] Exit code $LASTEXITCODE for '$($App.name)'."
        return $false
    }
    catch {
        Write-Warning "  [PAC] Install failed for '$($App.name)'. $($_.Exception.Message)"
        return $false
    }
}

# =====================================================================
# Environment app functions (stubs - point at your tenant's routes)
# =====================================================================
function Get-EnvironmentApps {
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,
        [Parameter(Mandatory)] [string] $BapToken,
        [Parameter(Mandatory)] [string] $PpToken
    )

    # Return objects with: name, appId, installedVersion, availableVersion, state
    #
    # $resp = Invoke-Bap -Method GET `
    #     -Path "/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId/applicationPackages" `
    #     -Token $BapToken
    # return $resp.value | ForEach-Object { [pscustomobject]@{
    #     name=$_.properties.applicationName; appId=$_.properties.applicationId
    #     installedVersion=$_.properties.installedVersion
    #     availableVersion=$_.properties.availableVersion; state=$_.properties.state } }

    throw 'Get-EnvironmentApps is a stub. Point it at the app inventory endpoint your tenant exposes.'
}

function Install-AppUpdate {
    param(
        [Parameter(Mandatory)] [string] $EnvironmentId,
        [Parameter(Mandatory)] [object] $App,
        [Parameter(Mandatory)] [string] $BapToken
    )

    # Example install call. Replace with the install route your tenant uses,
    # then poll for completion using $Config.PollIntervalSec / PollTimeoutMin.
    # Let any error propagate; the caller inspects it for the SPA restriction.
    #
    # $null = Invoke-Bap -Method POST `
    #     -Path "/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$EnvironmentId/applicationPackages/$($App.appId)/install" `
    #     -Token $BapToken

    throw 'Install-AppUpdate is a stub. Point it at the install endpoint your tenant exposes, then poll for completion.'
}

# ---------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------
$filterList  = Split-List $envFilter
$excludeList = Split-List $envExclude
$appExclude  = Split-List $appExcludeIn

Write-Section 'Effective settings'
Write-Host ("  DumpDiagnostics     : {0}" -f $dumpDiag)
Write-Host ("  RetryFailedInstalls : {0}" -f $retry)
Write-Host ("  WhatIf (plan only)  : {0}" -f $planOnly)
Write-Host ("  UsePacFallback      : {0}" -f $usePac)
Write-Host ("  EnvironmentFilter   : {0}" -f ($(if ($filterList.Count -eq 0)  { '(all)' }  else { $filterList  -join ', ' })))
Write-Host ("  EnvironmentExclude  : {0}" -f ($(if ($excludeList.Count -eq 0) { '(none)' } else { $excludeList -join ', ' })))
Write-Host ("  AppExclude          : {0}" -f ($(if ($appExclude.Count -eq 0)  { '(none)' } else { $appExclude  -join ', ' })))

Write-Section 'Authenticating'
$bapToken = Get-Token -Scope "$($Config.BapResource).default"
$ppToken  = Get-Token -Scope $Config.PowerPlatformScope
Write-Host 'Acquired Power Platform and BAP tokens'

Write-Section 'Listing environments'
$envResp = Invoke-Bap -Method GET `
    -Path '/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?$expand=properties' `
    -Token $bapToken

$allEnvironments = @($envResp.value)
Write-Host "Found $($allEnvironments.Count) environment(s) on the tenant"

$environments = foreach ($e in $allEnvironments) {
    $inFilter  = ($filterList.Count -eq 0) -or (Test-InList -Environment $e -List $filterList)
    $inExclude = Test-InList -Environment $e -List $excludeList
    if ($inExclude) { Write-Host "  Skipping (excluded): $($e.properties.displayName)"; continue }
    if (-not $inFilter) { continue }
    $e
}
$environments = @($environments)
Write-Host "Processing $($environments.Count) environment(s) after filter and exclude."

$summary = New-Object System.Collections.Generic.List[object]

foreach ($env in $environments) {
    $envId   = $env.name
    $envName = $env.properties.displayName

    Write-Section "Environment: $envName"

    try {
        $apps = Get-EnvironmentApps -EnvironmentId $envId -BapToken $bapToken -PpToken $ppToken
    }
    catch {
        Write-Warning "Could not read apps for '$envName'. $($_.Exception.Message)"
        continue
    }

    foreach ($app in $apps) {
        $needsUpdate = $app.availableVersion -and ($app.installedVersion -ne $app.availableVersion)
        $isFailed    = $app.state -ieq 'failed'
        $shouldRetry = $retry -and $isFailed
        $isExcluded  = Test-AppInList -App $app -List $appExclude

        $action = 'none'
        if ($isExcluded) {
            $action = 'skipped-excluded'
        }
        elseif ($needsUpdate -or $shouldRetry) {
            $action = 'update'
        }

        if ($dumpDiag) {
            Write-Host ("  {0,-45} installed: {1,-14} available: {2,-14} state: {3,-10} action: {4}" -f `
                $app.name, $app.installedVersion, $app.availableVersion, $app.state, $action)
        }

        if ($action -eq 'update') {
            if ($planOnly) {
                Write-Host "  [WhatIf] would update '$($app.name)' to $($app.availableVersion)"
            }
            else {
                try {
                    Install-AppUpdate -EnvironmentId $envId -App $app -BapToken $bapToken
                    Write-Host "  Updated '$($app.name)' to $($app.availableVersion)"
                }
                catch {
                    $errText = Get-ErrorText -ErrorRecord $_
                    if (Test-CustomInstallExperience -Message $errText) {
                        # This app needs the PPAC Custom Install Experience (SPA wizard).
                        $handled = $false
                        if ($usePac) {
                            Write-Host "  '$($app.name)' needs a custom install. Trying PAC CLI fallback..."
                            $handled = Invoke-PacInstall -EnvironmentId $envId -App $app
                        }
                        if ($handled) {
                            $action = 'update'
                            Write-Host "  Updated '$($app.name)' via PAC CLI."
                        }
                        else {
                            $action = 'manual-required'
                            Write-Host "  '$($app.name)' requires manual install via Power Platform Admin Center. Consider adding it to AppExclude."
                        }
                    }
                    else {
                        $action = 'failed'
                        Write-Warning "  Failed to update '$($app.name)'. $errText"
                    }
                }
            }
        }

        $summary.Add([pscustomobject]@{
            Environment      = $envName
            App              = $app.name
            InstalledVersion = $app.installedVersion
            AvailableVersion = $app.availableVersion
            State            = $app.state
            Action           = $action
        })
    }
}

Write-Section 'Summary'
$updated = @($summary | Where-Object { $_.Action -eq 'update' })
$manual  = @($summary | Where-Object { $_.Action -eq 'manual-required' })
$failed  = @($summary | Where-Object { $_.Action -eq 'failed' })
$exApps  = @($summary | Where-Object { $_.Action -eq 'skipped-excluded' })

Write-Host "Environments processed   : $($environments.Count)"
Write-Host "Apps evaluated           : $($summary.Count)"
Write-Host "Apps updated / planned   : $($updated.Count)"
Write-Host "Apps skipped (excluded)  : $($exApps.Count)"
Write-Host "Manual install required  : $($manual.Count)"
Write-Host "Failed                   : $($failed.Count)"

if ($manual.Count -gt 0) {
    Write-Section 'Manual install required (use Power Platform Admin Center)'
    $manual | Sort-Object Environment, App | Format-Table Environment, App, InstalledVersion, AvailableVersion -AutoSize | Out-String | Write-Host
    Write-Host 'These apps use a Custom Install Experience and cannot be installed by the API. Add them to AppExclude to silence future runs.'
}

if ($dumpDiag -and $summary.Count -gt 0) {
    Write-Section 'Installed vs available (all apps)'
    $summary | Sort-Object Environment, App | Format-Table -AutoSize | Out-String | Write-Host
}

Write-Host ''
Write-Host 'Done.'
