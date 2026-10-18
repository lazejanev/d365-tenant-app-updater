# Apply: execute plan actions and wait for app installs.
#
# With -Revalidate (Apply mode, reading plan.json), every action is checked
# against the live tenant first: the plan may be hours old, or an approver
# may have waited a day. An action is only executed when it is still exactly
# what was planned; anything else is reported, never improvised.

$script:PollSleep = { param([int] $Seconds) Start-Sleep -Seconds $Seconds }
$script:PollIntervalSeconds = 30
$script:PacReady = $false

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

function Initialize-Pac {
    param($Settings)
    if ($script:PacReady) { return $true }
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) { Write-RunWarning 'usePacFallback: the Power Platform CLI (pac) is not installed on the agent.'; return $false }
    try {
        & pac auth create --name d365updater --applicationId $Settings.ClientId --clientSecret $Settings.ClientSecret --tenant $Settings.TenantId 2>&1 | Out-Null
        $ok = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        $script:PacReady = $ok
        return $ok
    }
    catch { $global:LASTEXITCODE = 0; return $false }
}

function Invoke-PacInstall {
    param($Settings, [string] $EnvironmentId, [string] $UniqueName)
    if (-not (Initialize-Pac $Settings)) { return $false }
    try {
        # Output goes to the log, never to the pipeline: the caller needs a
        # plain bool back (a captured line of output would be truthy).
        & pac app-management install-application-package --environment $EnvironmentId --unique-name $UniqueName 2>&1 | ForEach-Object { Write-Line "    [pac] $_" }
        if ($LASTEXITCODE -eq 0) { $global:LASTEXITCODE = 0; return $true }
        & pac application install --environment-id $EnvironmentId --application-name $UniqueName 2>&1 | ForEach-Object { Write-Line "    [pac] $_" }
        $ok = ($LASTEXITCODE -eq 0)
        $global:LASTEXITCODE = 0
        return $ok
    }
    catch { $global:LASTEXITCODE = 0; return $false }
}

function New-ActionResult {
    param($Action, [string] $Result, [string] $Detail = '', [string] $OperationId = '')
    return [pscustomobject]@{
        Phase = $Action.Phase; Kind = $Action.Kind; Ring = $Action.Ring
        EnvironmentId = $Action.EnvironmentId; EnvironmentName = $Action.EnvironmentName
        AppUniqueName = $Action.AppUniqueName; AppName = $Action.AppName
        From = $Action.From; To = $Action.To; Reason = [string]$Action.Reason
        Result = $Result; Detail = $Detail; OperationId = $OperationId
    }
}

function Get-OperationIdFromResponse {
    param($Response)
    if ($Response.Json) {
        if ($Response.Json.PSObject.Properties['lastOperation'] -and $Response.Json.lastOperation -and $Response.Json.lastOperation.operationId) { return [string]$Response.Json.lastOperation.operationId }
        if ($Response.Json.PSObject.Properties['operationId'] -and $Response.Json.operationId) { return [string]$Response.Json.operationId }
    }
    return ''
}

function Get-RevalidatedApp {
    <#
    .SYNOPSIS
        Re-reads one environment's packages and solutions (cached per
        environment for the run) and checks an app action is still valid.
        Returns { Ok; Result; Detail; Package }.
    #>
    param($Settings, $Action, [hashtable] $Cache)
    $envId = $Action.EnvironmentId
    if (-not $Cache.ContainsKey($envId)) {
        $envObj = [pscustomobject]@{ Id = $envId; DisplayName = $Action.EnvironmentName; InstanceUrl = $Action.InstanceUrl; Ring = $Action.Ring; Sku = '' }
        $Cache[$envId] = Get-AppEnvironmentState -Settings $Settings -EnvObj $envObj
    }
    $st = $Cache[$envId]
    if ($st.PackagesError) { return [pscustomobject]@{ Ok = $false; Result = 'Failed'; Detail = "re-check failed: $($st.PackagesError)"; Package = $null } }
    $pkg = $st.Packages | Where-Object { [string]$_.uniqueName -eq $Action.AppUniqueName } | Select-Object -First 1
    if (-not $pkg) { return [pscustomobject]@{ Ok = $false; Result = 'Stale'; Detail = 'the app is no longer offered for this environment'; Package = $null } }
    if ([string]$pkg.state -eq 'Installed') {
        if ($st.SolutionsError) { return [pscustomobject]@{ Ok = $false; Result = 'Failed'; Detail = "re-check failed: $($st.SolutionsError)"; Package = $null } }
        $inst = Resolve-InstalledApp -Pkg $pkg -Map $st.Solutions
        if ($inst -and (Test-VersionAtLeast -Version $inst.Version -Minimum $Action.To)) { return [pscustomobject]@{ Ok = $false; Result = 'AlreadyDone'; Detail = "already at $($inst.Version)"; Package = $null } }
    }
    elseif ([string]$pkg.state -ne 'InstallFailed') {
        return [pscustomobject]@{ Ok = $false; Result = 'Stale'; Detail = "app state is now '$($pkg.state)'"; Package = $null }
    }
    if ([string]$pkg.version -ne [string]$Action.To) {
        return [pscustomobject]@{ Ok = $false; Result = 'Stale'; Detail = "the available version changed from $($Action.To) to $($pkg.version) since the plan; it is picked up by the next plan"; Package = $null }
    }
    return [pscustomobject]@{ Ok = $true; Result = ''; Detail = ''; Package = $pkg }
}

function Invoke-AppAction {
    param($Settings, $Action, $Package)
    $uri = New-PpUrl -Settings $Settings -Path "/appmanagement/environments/$($Action.EnvironmentId)/applicationPackages/$($Action.AppUniqueName)/install"
    $body = $Package | ConvertTo-Json -Depth 20 -Compress
    $r = Invoke-Http -Method 'POST' -Uri $uri -Headers (Get-PpHeaders $Settings) -Body $body -ContentType 'application/json'
    if (Test-HttpOk $r) {
        $op = Get-OperationIdFromResponse $r
        return New-ActionResult -Action $Action -Result 'Started' -Detail 'install accepted' -OperationId $op
    }
    $msg = "$(Format-RestFailure $r). $(Get-ApiErrorMessage $r)"
    if (Test-EnvironmentNotEnabled -Message $msg) { return New-ActionResult -Action $Action -Result 'AdminMode' -Detail 'environment is not enabled (Admin Mode)' }
    if (Test-CustomInstallExperience -Message $msg) {
        if ($Settings.UsePacFallback -and (Invoke-PacInstall -Settings $Settings -EnvironmentId $Action.EnvironmentId -UniqueName $Action.AppUniqueName)) {
            return New-ActionResult -Action $Action -Result 'Started' -Detail 'installed via PAC CLI fallback'
        }
        return New-ActionResult -Action $Action -Result 'Manual' -Detail 'needs the Power Platform admin center install wizard'
    }
    return New-ActionResult -Action $Action -Result 'Failed' -Detail $msg
}

function Invoke-FinOpsAction {
    param($Settings, $Action, [bool] $Revalidate)
    if ($Revalidate) {
        $vr = Invoke-Http -Method 'GET' -Uri (New-FinOpsUri -Settings $Settings -EnvironmentId $Action.EnvironmentId -Leaf 'finopsversions') -Headers (Get-PpHeaders $Settings)
        if (-not (Test-HttpOk $vr)) { return New-ActionResult -Action $Action -Result 'Failed' -Detail "re-check failed: $(Format-RestFailure $vr)" }
        $offered = @(ConvertTo-FinOpsVersionList -Json $vr.Json | ForEach-Object { $_.Version })
        if ($offered -notcontains [string]$Action.To) {
            return New-ActionResult -Action $Action -Result 'Stale' -Detail "$($Action.To) is no longer offered (already applied, or superseded by a newer PQU); the next plan decides again"
        }
    }
    $uri = New-FinOpsUri -Settings $Settings -EnvironmentId $Action.EnvironmentId -Leaf ("finopsversions/$($Action.To)/apply")
    $r = Invoke-Http -Method 'POST' -Uri $uri -Headers (Get-PpHeaders $Settings)
    if (-not $r.Transport -and $r.Status -eq 202) {
        return New-ActionResult -Action $Action -Result 'Started' -Detail 'accepted; applying now, the next run verifies it' -OperationId (Get-OperationIdFromResponse $r)
    }
    if (-not $r.Transport -and $r.Status -eq 204) { return New-ActionResult -Action $Action -Result 'AlreadyDone' -Detail 'platform confirms nothing is needed (204)' }
    return New-ActionResult -Action $Action -Result 'Failed' -Detail "apply failed: $(Format-RestFailure $r). $(Get-ApiErrorMessage $r)"
}

function Split-AllowedActions {
    <#
    .SYNOPSIS
        Apply mode: re-checks each planned action against the CURRENT
        settings. Returns { Allowed; Stopped } where Stopped are results with
        Result 'Stopped' and the reason.
    #>
    param($Settings, $Actions, $Plan)
    $allowed = @()
    $stopped = @()
    foreach ($a in $Actions) {
        $envObj = [pscustomobject]@{ Id = $a.EnvironmentId; DisplayName = $a.EnvironmentName }
        $why = ''
        if (Test-EnvInList -EnvObj $envObj -List $Settings.EnvironmentExclude) { $why = 'environment is now in environmentExclude' }
        elseif ((Get-Count $Settings.EnvironmentFilter) -gt 0 -and -not (Test-EnvInList -EnvObj $envObj -List $Settings.EnvironmentFilter)) { $why = 'environment is no longer in environmentFilter' }
        elseif ($a.Phase -eq 'Apps') {
            $pkgLike = [pscustomobject]@{ uniqueName = $a.AppUniqueName; localizedName = $a.AppName; applicationName = ''; applicationId = '' }
            $ex = Test-AppExcluded -Pkg $pkgLike -List $Settings.AppExclude
            if ($ex.Excluded) { $why = "app is now in appExclude ('$($ex.By)')" }
        }
        else {
            if (-not $Settings.FinOpsApplyVersion) { $why = 'finOpsApplyVersion is now false' }
            elseif ((Get-Count $Settings.FinOpsEnvironmentFilter) -gt 0 -and -not (Test-EnvInList -EnvObj $envObj -List $Settings.FinOpsEnvironmentFilter)) { $why = 'environment is no longer in finOpsEnvironmentFilter' }
        }
        if (-not $why -and $a.Ring -eq 'Production' -and $Settings.ProductionRing -and $Plan.PSObject.Properties['productionRing'] -and -not $Plan.productionRing) {
            $why = 'productionRing is now on, but the plan was made without it (not proven)'
        }
        if ($why) { $stopped += New-ActionResult -Action $a -Result 'Stopped' -Detail $why }
        else { $allowed += $a }
    }
    return [pscustomobject]@{ Allowed = $allowed; Stopped = $stopped }
}

function Invoke-PlanActions {
    <#
    .SYNOPSIS
        Runs the given (already ordered) actions. -DryRun only re-checks and
        reports what would happen.
    #>
    param($Settings, $Actions, [bool] $Revalidate = $false, [bool] $DryRun = $false, [hashtable] $InstanceUrls = @{})
    $results = @()
    $cache = @{}
    $adminMode = @{}
    $currentEnv = ''
    foreach ($a in $Actions) {
        if ($a.EnvironmentId -ne $currentEnv) {
            $currentEnv = $a.EnvironmentId
            Write-Line ''
            Write-Line "$($a.EnvironmentName) [$($a.Ring)]"
        }
        $label = "  $($a.AppName): $($a.From) -> $($a.To)"
        if ($adminMode.ContainsKey($a.EnvironmentId) -and $a.Phase -eq 'Apps') {
            $results += New-ActionResult -Action $a -Result 'AdminMode' -Detail 'skipped, environment is in Admin Mode'
            Write-Line "$label - skipped (Admin Mode)"
            continue
        }
        try {
            $res = $null
            if ($a.Phase -eq 'Apps') {
                $pkg = $a.Package
                if ($Revalidate) {
                    if (-not $a.PSObject.Properties['InstanceUrl'] -or -not $a.InstanceUrl) { $a | Add-Member -NotePropertyName InstanceUrl -NotePropertyValue ([string]$InstanceUrls[$a.EnvironmentId]) -Force }
                    $chk = Get-RevalidatedApp -Settings $Settings -Action $a -Cache $cache
                    if (-not $chk.Ok) { $res = New-ActionResult -Action $a -Result $chk.Result -Detail $chk.Detail }
                    else { $pkg = $chk.Package }
                }
                if (-not $res) {
                    if ($DryRun) { $res = New-ActionResult -Action $a -Result 'WouldApply' -Detail 'whatIf' }
                    else { $res = Invoke-AppAction -Settings $Settings -Action $a -Package $pkg }
                }
                if ($res.Result -eq 'AdminMode') { $adminMode[$a.EnvironmentId] = $true }
            }
            else {
                if ($DryRun) {
                    $res = New-ActionResult -Action $a -Result 'WouldApply' -Detail 'whatIf'
                    if ($Revalidate) {
                        $vr = Invoke-Http -Method 'GET' -Uri (New-FinOpsUri -Settings $Settings -EnvironmentId $a.EnvironmentId -Leaf 'finopsversions') -Headers (Get-PpHeaders $Settings)
                        if ((Test-HttpOk $vr) -and (@(ConvertTo-FinOpsVersionList -Json $vr.Json | ForEach-Object { $_.Version }) -notcontains [string]$a.To)) {
                            $res = New-ActionResult -Action $a -Result 'Stale' -Detail "$($a.To) is no longer offered"
                        }
                    }
                }
                else { $res = Invoke-FinOpsAction -Settings $Settings -Action $a -Revalidate $Revalidate }
            }
        }
        catch { $res = New-ActionResult -Action $a -Result 'Failed' -Detail (Get-ErrorText $_) }

        $results += $res
        $line = "$label - $($res.Result)"
        if ($res.Detail) { $line += " ($($res.Detail))" }
        if ($res.OperationId) { $line += " op $($res.OperationId)" }
        Write-Line $line
        if ($res.Result -eq 'Failed') { Write-RunWarning "$($a.EnvironmentName): $($a.AppName) $($a.To) failed: $($res.Detail)" }
    }
    return $results
}

function ConvertTo-OperationState {
    param($Json)
    if ($null -eq $Json) { return '' }
    foreach ($p in @('status', 'state', 'operationStatus')) {
        if ($Json.PSObject.Properties[$p] -and $Json.$p) { return [string]$Json.$p }
    }
    return ''
}

function Wait-AppOperations {
    <#
    .SYNOPSIS
        Polls started app installs until each one finishes or
        waitForInstallsMinutes passes. Updates Result to Succeeded, Failed or
        TimedOut. F&O applies run for hours and are verified by the next run.
    #>
    param($Settings, $Results)
    $pending = @($Results | Where-Object { $_.Phase -eq 'Apps' -and $_.Result -eq 'Started' -and $_.OperationId })
    if ((Get-Count $pending) -eq 0 -or $Settings.WaitForInstallsMinutes -le 0) { return }
    Write-Section "Waiting for $((Get-Count $pending)) app install(s) (up to $($Settings.WaitForInstallsMinutes) minutes)"
    $deadline = (Get-Now).AddMinutes($Settings.WaitForInstallsMinutes)
    while ($true) {
        foreach ($p in $pending) {
            if ($p.Result -ne 'Started') { continue }
            $uri = New-PpUrl -Settings $Settings -Path "/appmanagement/environments/$($p.EnvironmentId)/operations/$($p.OperationId)"
            $r = Invoke-Http -Method 'GET' -Uri $uri -Headers (Get-PpHeaders $Settings)
            if (-not (Test-HttpOk $r)) { continue }
            $state = ConvertTo-OperationState $r.Json
            if ($state -match '^(?i)(succeeded|completed|success)$') { $p.Result = 'Succeeded'; $p.Detail = 'install completed'; Write-Line "  $($p.EnvironmentName): $($p.AppName) $($p.To) - succeeded" }
            elseif ($state -match '^(?i)(failed|canceled|cancelled|error)$') {
                $why = Get-ApiErrorMessage $r
                if ($r.Json.PSObject.Properties['error'] -and $r.Json.error -and $r.Json.error.message) { $why = [string]$r.Json.error.message }
                if ($why.Length -gt 300) { $why = $why.Substring(0, 300) + '...' }
                $p.Result = 'Failed'; $p.Detail = "install $($state.ToLowerInvariant()): $why"
                Write-RunWarning "$($p.EnvironmentName): $($p.AppName) $($p.To) install $($state.ToLowerInvariant())."
            }
        }
        if ((Get-Count @($pending | Where-Object { $_.Result -eq 'Started' })) -eq 0) { return }
        if ((Get-Now) -ge $deadline) { break }
        & $script:PollSleep $script:PollIntervalSeconds
    }
    foreach ($p in $pending) {
        if ($p.Result -eq 'Started') { $p.Result = 'TimedOut'; $p.Detail = "still running after $($Settings.WaitForInstallsMinutes) minutes; checked again by the next run" }
    }
}
