# One HTTP helper for every call. It never throws: it returns
# { Status; Text; Json; Transport; Headers } so callers decide what a
# failure means. 429 and 503 are retried for GET only (Retry-After honoured,
# max 3 tries): a POST (install, apply) is never sent twice.

$script:HttpMaxAttempts = 3
$script:HttpSleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }

function Invoke-Http {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)] [string] $Uri,
        [hashtable] $Headers = @{},
        [AllowEmptyString()] [string] $Body = '',
        [string] $ContentType = 'application/json'
    )
    $attempt = 0
    while ($true) {
        $attempt++
        $status = 0; $text = ''; $transport = $false; $respHeaders = @{}
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $Headers; SkipHttpErrorCheck = $true; ErrorAction = 'Stop' }
            if ($Body -ne '') { $p['Body'] = $Body; $p['ContentType'] = $ContentType }
            $r = Invoke-WebRequest @p
            $status = [int]$r.StatusCode
            if ($null -ne $r.Content) {
                if ($r.Content -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($r.Content) } else { $text = [string]$r.Content }
            }
            if ($r.Headers) { $respHeaders = $r.Headers }
        }
        catch {
            $transport = $true
            $text = Get-ErrorText -ErrorRecord $_
        }

        if (-not $transport -and $Method -eq 'GET' -and ($status -eq 429 -or $status -eq 503) -and $attempt -lt $script:HttpMaxAttempts) {
            $wait = 5 * $attempt
            $ra = $null
            if ($respHeaders -and $respHeaders['Retry-After']) { $ra = [string](@($respHeaders['Retry-After'])[0]) }
            $n = 0
            if ($ra -and [int]::TryParse($ra, [ref]$n) -and $n -gt 0 -and $n -le 60) { $wait = $n }
            & $script:HttpSleep $wait
            continue
        }

        $json = $null
        if ($text -ne '') {
            $t = $text.Trim()
            $i = $t.IndexOfAny([char[]]@('{', '['))
            if ($i -ge 0) { try { $json = $t.Substring($i) | ConvertFrom-Json -Depth 50 } catch { $json = $null } }
        }
        return [pscustomobject]@{ Status = $status; Text = $text; Json = $json; Transport = $transport; Headers = $respHeaders }
    }
}

function Test-HttpOk {
    param($Response)
    return ($null -ne $Response -and -not $Response.Transport -and $Response.Status -ge 200 -and $Response.Status -lt 300)
}

function Get-ApiErrorCode {
    param($Response)
    if ($null -eq $Response) { return '' }
    if ($Response.Json -and $Response.Json.PSObject.Properties['code'] -and $Response.Json.code) { return [string]$Response.Json.code }
    if ($Response.Json -and $Response.Json.PSObject.Properties['error'] -and $Response.Json.error -and $Response.Json.error.code) { return [string]$Response.Json.error.code }
    if ($Response.Text -and ([string]$Response.Text) -match 'does not match any known API routes') { return 'RouteNotFound' }
    return ''
}

function Get-ApiErrorMessage {
    param($Response)
    if ($null -eq $Response) { return '' }
    if ($Response.Json -and $Response.Json.PSObject.Properties['error'] -and $Response.Json.error -and $Response.Json.error.message) { return [string]$Response.Json.error.message }
    if ($Response.Json -and $Response.Json.PSObject.Properties['message'] -and $Response.Json.message) { return [string]$Response.Json.message }
    return [string]$Response.Text
}

function Format-RestFailure {
    param($Response)
    if ($null -eq $Response) { return 'no response' }
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
    param([Parameter(Mandatory)] $Settings, [Parameter(Mandatory)] [string] $Path, [hashtable] $Query = @{})
    $b = [System.UriBuilder]::new("$($Settings.PpApiRoot)$Path")
    $pairs = @()
    foreach ($k in ($Query.Keys | Sort-Object)) {
        $pairs += "$([System.Uri]::EscapeDataString([string]$k))=$([System.Uri]::EscapeDataString([string]$Query[$k]))"
    }
    $pairs += "api-version=$([System.Uri]::EscapeDataString($Settings.AppManagementApiVersion))"
    $b.Query = [string]::Join('&', $pairs)
    return $b.Uri.AbsoluteUri
}

function New-FinOpsUri {
    param([Parameter(Mandatory)] $Settings, [string] $EnvironmentId, [string] $Leaf)
    return ($Settings.PpApiRoot + '/dynamics/environments/' + $EnvironmentId + '/' + $Leaf + '?api-version=' + $Settings.FinOpsApiVersion)
}
