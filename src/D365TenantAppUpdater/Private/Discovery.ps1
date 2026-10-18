# Environment discovery and ring assignment.
#
# Environments come from the BAP admin API: it is the admin-wide listing
# Microsoft documents. (The newer Power Platform API listing is "for the
# signed-in user", so it could miss environments; see docs/parameters.md.)

function Test-EnvInList {
    param($EnvObj, $List)
    if ((Get-Count $List) -eq 0) { return $false }
    foreach ($item in $List) {
        $needle = [string]$item
        if ($EnvObj.DisplayName -and ([string]$EnvObj.DisplayName) -ieq $needle) { return $true }
        if ($EnvObj.Id -and ([string]$EnvObj.Id) -ieq $needle) { return $true }
    }
    return $false
}

function Get-EnvironmentRing {
    <#
    .SYNOPSIS
        Production or NonProduction, decided only from what the platform
        reports, so nobody maintains a list:
          - named in productionEnvironments            -> Production
          - PPAC environment type in productionEnvironmentTypes
            (default: Production)                       -> Production
          - F&O deployment type UnifiedProduction or LCSProduction -> Production
          - environment type not reported              -> Production (fail safe)
          - anything else                              -> NonProduction
    #>
    param($EnvObj, $Settings, [AllowEmptyString()] [string] $FinOpsDeploymentType = '')
    if (Test-EnvInList -EnvObj $EnvObj -List $Settings.ProductionEnvironments) { return 'Production' }
    foreach ($t in $Settings.ProductionEnvironmentTypes) { if ([string]$EnvObj.Sku -ieq [string]$t) { return 'Production' } }
    if ($FinOpsDeploymentType -ieq 'UnifiedProduction' -or $FinOpsDeploymentType -ieq 'LCSProduction') { return 'Production' }
    # Unknown type: treat as production so it is never updated unproven.
    if ([string]::IsNullOrWhiteSpace([string]$EnvObj.Sku)) { return 'Production' }
    return 'NonProduction'
}

function Get-TenantEnvironments {
    <#
    .SYNOPSIS
        Lists every Dataverse-linked environment, applies environmentFilter
        and environmentExclude, assigns rings, and sorts A to Z.
        Throws when the list cannot be read (the run cannot continue).
    #>
    param($Settings)
    $uri = "$($Settings.BapApiRoot)/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?`$expand=properties&api-version=$($Settings.BapApiVersion)"
    $all = @()
    $pages = 0
    $maxPages = 50
    while ($uri -and $pages -lt $maxPages) {
        $pages++
        $r = Invoke-Http -Method 'GET' -Uri $uri -Headers (Get-BapHeaders $Settings)
        if (-not (Test-HttpOk $r)) { throw "Could not list environments: $(Format-RestFailure $r). $(Get-ApiErrorMessage $r)" }
        foreach ($e in @($r.Json.value)) { $all += $e }
        $uri = $null
        if ($r.Json.PSObject.Properties['nextLink'] -and $r.Json.nextLink) { $uri = [string]$r.Json.nextLink }
    }
    $warnings = @()
    if ($uri) { $warnings += "The environment list has more than $maxPages pages; only the first $maxPages were read." }

    $environments = @()
    $skippedNoDataverse = 0
    foreach ($e in $all) {
        $instanceUrl = $null
        if ($e.properties -and $e.properties.linkedEnvironmentMetadata) { $instanceUrl = $e.properties.linkedEnvironmentMetadata.instanceUrl }
        if (-not $instanceUrl) { $skippedNoDataverse++; continue }
        $dn = [string]$e.name
        if ($e.properties.displayName) { $dn = [string]$e.properties.displayName }
        $sku = ''
        if ($e.properties.PSObject.Properties['environmentSku'] -and $e.properties.environmentSku) { $sku = [string]$e.properties.environmentSku }
        $obj = [pscustomobject]@{ Id = [string]$e.name; DisplayName = $dn; InstanceUrl = [string]$instanceUrl; Sku = $sku; Ring = 'NonProduction' }
        $obj.Ring = Get-EnvironmentRing -EnvObj $obj -Settings $Settings
        if (-not $sku -and $Settings.ProductionRing) { $warnings += "$dn`: the environment type was not reported, so it is treated as production." }
        $environments += $obj
    }

    $scoped = @()
    $excluded = @()
    foreach ($envObj in $environments) {
        if (Test-EnvInList -EnvObj $envObj -List $Settings.EnvironmentExclude) { $excluded += $envObj; continue }
        if ((Get-Count $Settings.EnvironmentFilter) -gt 0 -and -not (Test-EnvInList -EnvObj $envObj -List $Settings.EnvironmentFilter)) { continue }
        $scoped += $envObj
    }

    return [pscustomobject]@{
        All          = @(Sort-ByDisplayName $environments)
        InScope      = @(Sort-ByDisplayName $scoped)
        Excluded     = @(Sort-ByDisplayName $excluded)
        NoDataverse  = $skippedNoDataverse
        Warnings     = $warnings
    }
}
