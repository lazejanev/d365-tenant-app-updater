# Sign-in.
#
# Two ways to sign in as the app registration (service principal):
#   ClientSecret - client_credentials with the secret (v2 behaviour).
#   Federated    - client_credentials with a client assertion: a short-lived
#                  OIDC token from the CI platform, so no secret is stored.
#                  GitHub Actions: the job's OIDC token (needs
#                  'permissions: id-token: write').
#                  Azure DevOps: the pipeline's OIDC token for a service
#                  connection with workload identity federation
#                  (System.OidcRequestUri + System.AccessToken).
#   Auto (default) - Federated when the platform offers it, else ClientSecret.
#
# Tokens are cached per scope and renewed 5 minutes before they expire, so
# runs longer than a token's lifetime keep working. A federated assertion is
# fetched fresh for every token request (they live only minutes).

$script:TokenCache = @{}
$script:AuthState = $null

function Test-GitHubOidcAvailable {
    return (-not [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -and -not [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN))
}

function Get-AdoServiceConnectionId {
    param($Settings)
    if (-not (Test-Unset $Settings.ServiceConnectionId)) { return $Settings.ServiceConnectionId }
    if (-not (Test-Unset $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID)) { return $env:AZURESUBSCRIPTION_SERVICE_CONNECTION_ID }
    return ''
}

function Test-AdoOidcAvailable {
    param($Settings)
    return (-not (Test-Unset $env:SYSTEM_OIDCREQUESTURI) -and -not (Test-Unset $env:SYSTEM_ACCESSTOKEN) -and (Get-AdoServiceConnectionId $Settings) -ne '')
}

function Resolve-AuthMode {
    <#
    .SYNOPSIS
        Decides how to sign in. Throws with a plain explanation when neither
        way is configured.
    #>
    param($Settings)
    $hasSecret = -not (Test-Unset $Settings.ClientSecret)
    $fedSource = ''
    if (Test-GitHubOidcAvailable) { $fedSource = 'GitHub' }
    elseif (Test-AdoOidcAvailable $Settings) { $fedSource = 'AzureDevOps' }

    switch ($Settings.AuthMode) {
        'ClientSecret' {
            if (-not $hasSecret) { throw 'authMode is ClientSecret, but no client secret was provided (ClientSecret / D365_CLIENT_SECRET).' }
            return [pscustomobject]@{ Mode = 'ClientSecret'; Source = '' }
        }
        'Federated' {
            if ($fedSource -eq '') {
                throw ('authMode is Federated, but no OIDC token source was found. On GitHub add "permissions: id-token: write" to the job. ' +
                       'On Azure DevOps use azure-pipelines-federated.yml with a workload identity federation service connection and set serviceConnectionId.')
            }
            return [pscustomobject]@{ Mode = 'Federated'; Source = $fedSource }
        }
        default {
            if ($fedSource -ne '') { return [pscustomobject]@{ Mode = 'Federated'; Source = $fedSource } }
            if ($hasSecret) { return [pscustomobject]@{ Mode = 'ClientSecret'; Source = '' } }
            throw 'No way to sign in: provide a client secret, or run with OIDC (GitHub "id-token: write", or the Azure DevOps federated pipeline).'
        }
    }
}

function Get-FederatedAssertion {
    param($Settings, [string] $Source)
    if ($Source -eq 'GitHub') {
        $sep = '&'
        if ($env:ACTIONS_ID_TOKEN_REQUEST_URL -notmatch '\?') { $sep = '?' }
        $uri = $env:ACTIONS_ID_TOKEN_REQUEST_URL + $sep + 'audience=' + [Uri]::EscapeDataString('api://AzureADTokenExchange')
        $r = Invoke-Http -Method 'GET' -Uri $uri -Headers @{ Authorization = "Bearer $($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)"; Accept = 'application/json' }
        if (-not (Test-HttpOk $r) -or -not $r.Json.value) { throw "Could not get a GitHub OIDC token: $(Format-RestFailure $r)" }
        return [string]$r.Json.value
    }
    if ($Source -eq 'AzureDevOps') {
        $scId = Get-AdoServiceConnectionId $Settings
        $sep = '&'
        if ($env:SYSTEM_OIDCREQUESTURI -notmatch '\?') { $sep = '?' }
        $uri = $env:SYSTEM_OIDCREQUESTURI + $sep + 'api-version=7.1&serviceConnectionId=' + [Uri]::EscapeDataString($scId)
        $r = Invoke-Http -Method 'POST' -Uri $uri -Headers @{ Authorization = "Bearer $($env:SYSTEM_ACCESSTOKEN)" } -Body '{}' -ContentType 'application/json'
        if (-not (Test-HttpOk $r) -or -not $r.Json.oidcToken) { throw "Could not get an Azure DevOps OIDC token for service connection '$scId': $(Format-RestFailure $r)" }
        return [string]$r.Json.oidcToken
    }
    throw "Unknown federated token source '$Source'."
}

function ConvertTo-FormBody {
    param([System.Collections.IDictionary] $Fields)
    $pairs = @()
    foreach ($k in $Fields.Keys) { $pairs += ([Uri]::EscapeDataString([string]$k) + '=' + [Uri]::EscapeDataString([string]$Fields[$k])) }
    return [string]::Join('&', $pairs)
}

function Initialize-Auth {
    param($Settings)
    $script:TokenCache = @{}
    $script:AuthState = Resolve-AuthMode -Settings $Settings
    return $script:AuthState
}

function Request-Token {
    param($Settings, [string] $Scope)
    $fields = [ordered]@{ client_id = $Settings.ClientId; grant_type = 'client_credentials'; scope = $Scope }
    if ($script:AuthState.Mode -eq 'Federated') {
        $fields['client_assertion_type'] = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        try { $fields['client_assertion'] = Get-FederatedAssertion -Settings $Settings -Source $script:AuthState.Source }
        catch { return [pscustomobject]@{ Status = 0; Text = (Get-ErrorText $_); Json = $null; Transport = $true; Headers = @{} } }
    }
    else {
        $fields['client_secret'] = $Settings.ClientSecret
    }
    return Invoke-Http -Method 'POST' -Uri $Settings.Authority -Body (ConvertTo-FormBody $fields) -ContentType 'application/x-www-form-urlencoded'
}

function Get-AccessToken {
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Scope)
    $cached = $script:TokenCache[$Scope]
    if ($cached -and $cached.ExpiresAt -gt (Get-Now).AddMinutes(5)) { return $cached.Token }
    if (-not $script:AuthState) { $null = Initialize-Auth -Settings $Settings }

    $r = Request-Token -Settings $Settings -Scope $Scope
    # authMode = Auto: federated first, the client secret as the backup.
    # If the federated sign-in is refused (for example no federated
    # credential on the app registration yet) and a secret exists, switch
    # to the secret for the rest of the run.
    # Only the run's first token decides this: a later refusal for one
    # environment's Dataverse scope is not a federation problem.
    $firstToken = ($script:TokenCache.Count -eq 0)
    if ($firstToken -and (-not (Test-HttpOk $r) -or -not $r.Json.access_token) -and $script:AuthState.Mode -eq 'Federated' -and $Settings.AuthMode -eq 'Auto' -and -not (Test-Unset $Settings.ClientSecret)) {
        $why = Get-ApiErrorMessage $r
        if ($r.Json -and $r.Json.error_description) { $why = [string]$r.Json.error_description }
        Write-RunWarning "Federated sign-in ($($script:AuthState.Source) OIDC) was refused, so the client secret is used instead. Add the federated credential to stop using the secret. $(Format-RestFailure $r). $why"
        $script:AuthState = [pscustomobject]@{ Mode = 'ClientSecret'; Source = '' }
        $r = Request-Token -Settings $Settings -Scope $Scope
    }
    if (-not (Test-HttpOk $r) -or -not $r.Json.access_token) {
        $msg = Get-ApiErrorMessage $r
        if ($r.Json -and $r.Json.error_description) { $msg = [string]$r.Json.error_description }
        throw "Sign-in failed for scope '$Scope' ($($script:AuthState.Mode)): $(Format-RestFailure $r). $msg"
    }
    $lifetime = 3600
    $n = 0
    if ($r.Json.expires_in -and [int]::TryParse([string]$r.Json.expires_in, [ref]$n) -and $n -gt 0) { $lifetime = $n }
    $script:TokenCache[$Scope] = [pscustomobject]@{ Token = [string]$r.Json.access_token; ExpiresAt = (Get-Now).AddSeconds($lifetime) }
    return [string]$r.Json.access_token
}

function Get-PpHeaders {
    param($Settings)
    return @{ Authorization = "Bearer $(Get-AccessToken -Settings $Settings -Scope $Settings.PowerPlatformScope)"; Accept = 'application/json' }
}

function Get-BapHeaders {
    param($Settings)
    return @{ Authorization = "Bearer $(Get-AccessToken -Settings $Settings -Scope $Settings.BapScope)"; Accept = 'application/json' }
}

function Get-DataverseHeaders {
    param($Settings, [string] $InstanceUrl)
    $base = $InstanceUrl.TrimEnd('/')
    return @{
        Authorization      = "Bearer $(Get-AccessToken -Settings $Settings -Scope "$base/.default")"
        Accept             = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'    = '4.0'
    }
}
