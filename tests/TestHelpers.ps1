# Shared test helpers: a fake tenant that answers every HTTP call the module
# makes. Tests mock Invoke-WebRequest inside the module with
#   Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
# and describe the tenant with New-FakeEnv / Set-FakeTenant.

$global:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$global:ModuleManifest = Join-Path $global:RepoRoot 'src/D365TenantAppUpdater/D365TenantAppUpdater.psd1'
$global:FixtureDir = Join-Path $PSScriptRoot 'Fixtures'

function New-FakeApp {
    param(
        [string] $UniqueName, [string] $Name = '', [string] $Available = '1.0.0.1', [string] $Installed = '1.0.0.0',
        [string] $State = 'Installed', [string] $ModifiedOn = '2026-01-01T00:00:00Z'
    )
    if (-not $Name) { $Name = $UniqueName }
    return @{ UniqueName = $UniqueName; Name = $Name; Available = $Available; Installed = $Installed; State = $State; ModifiedOn = $ModifiedOn }
}

function New-FakeEnv {
    param(
        [string] $Id, [string] $Name, [string] $Sku = 'Sandbox', [object[]] $Apps = @(),
        [string] $FinOpsBuild = '', [string] $FinOpsDeployment = 'UnifiedSandbox', [string] $FinOpsVersions = '[]',
        [int] $PackagesStatus = 200, [int] $SolutionsStatus = 200, [int] $VersionsStatus = 200, [int] $PropsStatus = 200,
        [string] $VersionsBody = '', [hashtable] $InstallResponses = @{}, [string] $OperationStatus = 'Succeeded',
        [int] $ApplyStatus = 202, [switch] $NoDataverse
    )
    return @{
        Id = $Id; Name = $Name; Sku = $Sku; Url = "https://$($Id.ToLowerInvariant()).crm.dynamics.com/"; Apps = $Apps
        FinOpsBuild = $FinOpsBuild; FinOpsDeployment = $FinOpsDeployment; FinOpsVersions = $FinOpsVersions
        PackagesStatus = $PackagesStatus; SolutionsStatus = $SolutionsStatus; VersionsStatus = $VersionsStatus; PropsStatus = $PropsStatus
        VersionsBody = $VersionsBody; InstallResponses = $InstallResponses; OperationStatus = $OperationStatus
        ApplyStatus = $ApplyStatus; NoDataverse = [bool]$NoDataverse
    }
}

function Set-FakeTenant {
    param([object[]] $Environments, [string] $Schedule = 'pqu-schedule.md', [switch] $ScheduleFails, [int] $BapStatus = 200, [int] $TokenStatus = 200, [int] $PageSize = 0)
    $global:FakeTenant = @{
        Environments = $Environments; Schedule = $Schedule; ScheduleFails = [bool]$ScheduleFails
        BapStatus = $BapStatus; TokenStatus = $TokenStatus; PageSize = $PageSize
        Calls = [System.Collections.Generic.List[string]]::new()
        Bodies = [System.Collections.Generic.List[string]]::new()
    }
}

function New-FakeResponse {
    param([int] $Status = 200, $Body = $null, [hashtable] $Headers = @{})
    $content = ''
    if ($Body -is [string]) { $content = $Body }
    elseif ($null -ne $Body) { $content = $Body | ConvertTo-Json -Depth 20 -Compress }
    return [pscustomobject]@{ StatusCode = $Status; Content = $content; Headers = $Headers }
}

function Get-FakeEnvById {
    param([string] $Id)
    return $global:FakeTenant.Environments | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
}

function Invoke-FakeRequest {
    param($Method = 'GET', $Uri, $Headers, $Body, $ContentType, [switch] $SkipHttpErrorCheck, $ErrorAction)
    $u = [string]$Uri
    $m = ([string]$Method).ToUpperInvariant()
    $T = $global:FakeTenant
    $T.Calls.Add("$m $u")
    if ($Body) { $T.Bodies.Add([string]$Body) }

    if ($u -like '*oauth2/v2.0/token*') {
        if ($T.TokenStatus -ne 200) { return New-FakeResponse -Status $T.TokenStatus -Body @{ error = 'invalid_client'; error_description = 'AADSTS7000215: Invalid client secret provided.' } }
        return New-FakeResponse -Body @{ access_token = 'tok'; expires_in = 3599 }
    }
    if ($u -like '*quality-updates-schedule*') {
        if ($T.ScheduleFails) { return New-FakeResponse -Status 503 -Body 'Service Unavailable' }
        return New-FakeResponse -Body (Get-Content -Raw (Join-Path $global:FixtureDir $T.Schedule))
    }
    if ($u -like '*scopes/admin/environments*') {
        if ($T.BapStatus -ne 200) { return New-FakeResponse -Status $T.BapStatus -Body @{ error = @{ code = 'Forbidden'; message = 'The service principal is not a Power Platform administrator.' } } }
        $all = @(foreach ($e in $T.Environments) {
            $props = @{ displayName = $e.Name; environmentSku = $e.Sku }
            if (-not $e.NoDataverse) { $props['linkedEnvironmentMetadata'] = @{ instanceUrl = $e.Url } }
            @{ name = $e.Id; properties = $props }
        })
        $skip = 0
        if ($u -match 'skip=(\d+)') { $skip = [int]$Matches[1] }
        if ($T.PageSize -gt 0) {
            $page = @($all | Select-Object -Skip $skip -First $T.PageSize)
            $resp = @{ value = $page }
            if ($skip + $T.PageSize -lt $all.Count) { $resp['nextLink'] = "https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments?api-version=x&skip=$($skip + $T.PageSize)" }
            return New-FakeResponse -Body $resp
        }
        return New-FakeResponse -Body @{ value = $all }
    }
    if ($u -match '/appmanagement/environments/([^/]+)/applicationPackages/([^/?]+)/install') {
        $e = Get-FakeEnvById $Matches[1]; $un = $Matches[2]
        if ($e.InstallResponses.ContainsKey($un)) { $r = $e.InstallResponses[$un]; return New-FakeResponse -Status $r.Status -Body $r.Body }
        return New-FakeResponse -Body @{ lastOperation = @{ operationId = "op-$un" } }
    }
    if ($u -match '/appmanagement/environments/([^/]+)/applicationPackages') {
        $e = Get-FakeEnvById $Matches[1]
        if ($e.PackagesStatus -ne 200) { return New-FakeResponse -Status $e.PackagesStatus -Body @{ error = @{ code = 'Boom'; message = 'packages failed' } } }
        $pk = @(foreach ($a in $e.Apps) { @{ uniqueName = $a.UniqueName; localizedName = $a.Name; applicationName = $a.Name; state = $a.State; version = $a.Available } })
        if ($e.FinOpsBuild) { $pk += @{ uniqueName = 'msdyn_FinanceAndOperationsProvisioningAppAnchor'; localizedName = 'Finance and Operations Provisioning App'; state = 'Installed'; version = '10.0.99.1' } }
        return New-FakeResponse -Body @{ value = $pk }
    }
    if ($u -match '/appmanagement/environments/([^/]+)/operations/([^/?]+)') {
        $e = Get-FakeEnvById $Matches[1]
        $b = @{ status = $e.OperationStatus }
        if ($e.OperationStatus -eq 'Failed') { $b['error'] = @{ message = 'Solution import failed.' } }
        return New-FakeResponse -Body $b
    }
    if ($u -match '/api/data/v9\.2/solutions') {
        $e = $T.Environments | Where-Object { $u.StartsWith($_.Url.TrimEnd('/')) } | Select-Object -First 1
        if ($e.SolutionsStatus -ne 200) { return New-FakeResponse -Status $e.SolutionsStatus -Body @{ error = @{ code = '0x80040220'; message = 'Principal user is missing prvReadSolution.' } } }
        $sol = @(foreach ($a in $e.Apps) { if ($a.Installed) { @{ uniquename = $a.UniqueName; friendlyname = $a.Name; version = $a.Installed; modifiedon = $a.ModifiedOn } } })
        if ($e.FinOpsBuild) { $sol += @{ uniquename = 'msdyn_FinanceAndOperationsProvisioningAppAnchor'; friendlyname = 'Finance and Operations Provisioning App'; version = '10.0.48.6'; modifiedon = '2026-01-01T00:00:00Z' } }
        return New-FakeResponse -Body @{ value = $sol }
    }
    if ($u -match '/dynamics/environments/([^/]+)/finopsproperties') {
        $e = Get-FakeEnvById $Matches[1]
        if ($e.PropsStatus -ne 200) { return New-FakeResponse -Status $e.PropsStatus -Body @{ error = @{ code = 'Boom'; message = 'props failed' } } }
        return New-FakeResponse -Body @{ applicationVersion = $e.FinOpsBuild; platformVersion = '7.0.7996.119'; deploymentType = $e.FinOpsDeployment; lastObservedAOSCount = 2; maxAOSCount = 2 }
    }
    if ($u -match '/dynamics/environments/([^/]+)/finopsadminsettings') {
        return New-FakeResponse -Body @{ maintenanceWindowCadence = 'Weekly'; maintenanceWindowDaysOfWeek = @('Saturday') }
    }
    if ($u -match '/dynamics/environments/([^/]+)/finopsversions/([^/]+)/apply') {
        $e = Get-FakeEnvById $Matches[1]
        return New-FakeResponse -Status $e.ApplyStatus -Body $(if ($e.ApplyStatus -eq 202) { @{ operationId = 'fo-op' } } else { '' })
    }
    if ($u -match '/dynamics/environments/([^/]+)/finopsversions') {
        $e = Get-FakeEnvById $Matches[1]
        if ($e.VersionsStatus -ne 200) {
            if ($e.VersionsBody) { return New-FakeResponse -Status $e.VersionsStatus -Body $e.VersionsBody }
            return New-FakeResponse -Status $e.VersionsStatus -Body @{ error = @{ code = 'Boom'; message = 'versions failed' } }
        }
        return New-FakeResponse -Body $e.FinOpsVersions
    }
    throw "Unmocked request: $m $u"
}

function Get-FakeCalls {
    param([string] $Like)
    return @($global:FakeTenant.Calls | Where-Object { $_ -like $Like })
}

function Initialize-TestEnvironmentVariables {
    # Clears every setting variable so tests never inherit the machine's.
    $names = @('D365_CLIENT_ID', 'D365_CLIENT_SECRET', 'D365_TENANT_ID', 'AZURESUBSCRIPTION_CLIENT_ID', 'AZURESUBSCRIPTION_TENANT_ID', 'GITHUB_ACTIONS', 'TF_BUILD', 'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
        'SYSTEM_OIDCREQUESTURI', 'SYSTEM_ACCESSTOKEN', 'AZURESUBSCRIPTION_SERVICE_CONNECTION_ID', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'UpdateFinOpsVersion', 'FinOpsInventory',
        'Authority', 'BapApiRoot', 'BapApiVersion', 'PowerPlatformScope', 'PpApiRoot', 'AppManagementApiVersion', 'FinOpsApiVersion', 'DumpDiagnostics', 'DumpSolutionCatalog',
        'RetryFailedInstalls', 'WhatIf', 'EnvironmentFilter', 'EnvironmentExclude', 'AppExclude', 'UsePacFallback', 'FinOpsApplyVersion', 'FinOpsTargetVersion',
        'FinOpsEnvironmentFilter', 'FinOpsDeploymentTypes', 'FinOpsUpdateScope', 'FinOpsBuildTrainMap', 'FinOpsScheduleUrl', 'ProductionRing', 'ProductionEnvironmentTypes',
        'ProductionEnvironments', 'ProductionSoakDays', 'WaitForInstallsMinutes', 'FailOnIssues', 'AuthMode', 'ServiceConnectionId',
        'WhatIfOverride', 'UsePacFallbackOverride', 'FinOpsApplyVersionOverride', 'FinOpsUpdateScopeOverride', 'FinOpsTargetVersionOverride')
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
}

function Invoke-TestRun {
    <#
    .SYNOPSIS
        Runs Invoke-D365TenantAppUpdate against the fake tenant and returns
        { ExitCode; Report; Summary; Plan; Output; Dir }.
    #>
    param([hashtable] $Setting = @{}, [string] $Mode = 'PlanAndApply', [string] $Ring = 'All', [string] $PlanFile = '', [string] $OutputDirectory = '')
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ("d365tau-" + [guid]::NewGuid().ToString('N')) }
    $s = @{ DumpDiagnostics = 'false'; WaitForInstallsMinutes = '0' }
    foreach ($k in $Setting.Keys) { $s[$k] = $Setting[$k] }
    $out = & { Invoke-D365TenantAppUpdate -ClientId 'cid' -ClientSecret 'sec' -TenantId 'tid' -Mode $Mode -Ring $Ring -PlanFile $PlanFile -OutputDirectory $OutputDirectory -Setting $s } 6>&1
    $code = @($out | Where-Object { $_ -is [int] }) | Select-Object -Last 1
    $text = (@($out | Where-Object { $_ -isnot [int] }) | ForEach-Object { [string]$_ }) -join "`n"
    $report = $null; $summary = ''; $plan = $null
    if (Test-Path (Join-Path $OutputDirectory 'report.json')) { $report = Get-Content -Raw (Join-Path $OutputDirectory 'report.json') | ConvertFrom-Json -Depth 30 }
    if (Test-Path (Join-Path $OutputDirectory 'summary.md')) { $summary = Get-Content -Raw (Join-Path $OutputDirectory 'summary.md') }
    $pf = $PlanFile
    if (-not $pf) { $pf = Join-Path $OutputDirectory 'plan.json' }
    if (Test-Path $pf) { $plan = Get-Content -Raw $pf | ConvertFrom-Json -Depth 30 }
    return [pscustomobject]@{ ExitCode = $code; Report = $report; Summary = $summary; Plan = $plan; Output = $text; Dir = $OutputDirectory }
}

function Reset-TestModuleState {
    # Fresh module state for each test: local host, no real sleeping, no
    # cached tokens, and no leftover environment variables.
    param([string] $HostKind = 'Local')
    Initialize-TestEnvironmentVariables
    InModuleScope D365TenantAppUpdater -Parameters @{ K = $HostKind } {
        param($K)
        Set-HostKind $K
        $script:HttpSleep = { param([int] $Seconds) }
        $script:PollSleep = { param([int] $Seconds) }
        $script:TokenCache = @{}
        $script:AuthState = $null
        $script:PacReady = $false
    }
}
