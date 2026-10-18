# Collect -> plan.
#
# Everything is read first (all environments, A to Z), then decided, so the
# production ring can compare production against what non-production already
# runs, independent of the order environments are listed in.
# The plan is written to plan.json. An Apply run (a later stage or job,
# possibly behind an approval) reads it back, re-checks each action against
# the live tenant and only then changes anything.

$script:PlanSchema = 'd365-tenant-app-updater/plan@1'

function Invoke-Collect {
    <#
    .SYNOPSIS
        Reads apps and F&O data for every environment in scope.
        Returns { Environments; AppStates; FinOpsStates; ReleaseMap; Warnings; Errors }.
    #>
    param($Settings, $Discovery)
    $warnings = @()
    $errors = @()

    $appStates = @()
    $dumped = $false
    foreach ($envObj in $Discovery.InScope) {
        $dump = ($Settings.DumpSolutionCatalog -and -not $dumped)
        $st = Get-AppEnvironmentState -Settings $Settings -EnvObj $envObj -DumpCatalog $dump
        if ($dump -and -not $st.SolutionsError -and -not $st.PackagesError) { $dumped = $true }
        if ($st.PackagesError) { $errors += "$($envObj.DisplayName): could not list app packages: $($st.PackagesError)" }
        elseif ($st.SolutionsError) {
            $msg = "$($envObj.DisplayName): could not read installed solutions, apps skipped (nothing is installed blindly): $($st.SolutionsError)"
            $errors += $msg
        }
        $appStates += $st
    }

    # F&O environments: the provisioning app is installed (presence only).
    $foEnvs = @()
    foreach ($st in $appStates) {
        if (-not $st.FinOpsMarker) { continue }
        if ((Get-Count $Settings.FinOpsEnvironmentFilter) -gt 0 -and -not (Test-EnvInList -EnvObj $st.Env -List $Settings.FinOpsEnvironmentFilter)) { continue }
        $foEnvs += $st.Env
    }

    $releaseMap = $null
    $foStates = @()
    if ((Get-Count $foEnvs) -gt 0) {
        $releaseMap = Get-FinOpsReleaseMap -Settings $Settings
        if ($releaseMap.ScheduleError) { $warnings += "Microsoft's PQU schedule was not used ($($releaseMap.ScheduleError)). Using the built-in release map: $($releaseMap.Label). Environments on a newer release are skipped, not guessed." }
        if ((Get-Count $releaseMap.Ambiguous) -gt 0) { $warnings += "Microsoft's schedule lists these builds under more than one release, so environments on them are skipped: $(Join-Names $releaseMap.Ambiguous)" }
        if ((Get-Count $releaseMap.Invalid) -gt 0) { $warnings += "finOpsBuildTrainMap entries ignored (expected '10.0.<build>=<train>', e.g. 10.0.2790=49): $(Join-Names $releaseMap.Invalid)" }
        foreach ($e in $foEnvs) {
            $fs = Get-FinOpsEnvironmentState -Settings $Settings -EnvObj $e -TrainMap $releaseMap.Map
            # The F&O deployment type can make an environment Production.
            $ring = Get-EnvironmentRing -EnvObj $e -Settings $Settings -FinOpsDeploymentType $fs.DeploymentType
            if ($ring -ne $e.Ring) { $e.Ring = $ring }
            $foStates += $fs
        }
    }

    return [pscustomobject]@{
        Environments = $Discovery.InScope; AppStates = $appStates; FinOpsStates = $foStates
        ReleaseMap = $releaseMap; Warnings = $warnings; Errors = $errors
    }
}

function New-RunPlan {
    param($Settings, $Collected, [string] $Version)
    $apps = New-AppPlan -Settings $Settings -States $Collected.AppStates
    $fo = @(New-FinOpsPlan -Settings $Settings -States $Collected.FinOpsStates)
    $all = @($apps.Decisions) + $fo
    $plan = [pscustomobject]@{
        schema       = $script:PlanSchema
        toolVersion  = $Version
        createdUtc   = (Get-Now).ToString('o')
        tenantId     = $Settings.TenantId
        productionRing = $Settings.ProductionRing
        environments = @($Collected.Environments | ForEach-Object { [pscustomobject]@{ Id = $_.Id; DisplayName = $_.DisplayName; Ring = $_.Ring; Sku = $_.Sku; InstanceUrl = $_.InstanceUrl } })
        actions      = @($all | Where-Object { $_.Outcome -eq 'Action' })
        decisions    = @($all | Where-Object { $_.Outcome -ne 'Action' })
    }
    return [pscustomobject]@{ Plan = $plan; Warnings = @($apps.Warnings) }
}

function Get-OrderedActions {
    # Non-production first, then production; A to Z inside each ring, apps
    # before F&O for the same environment.
    param($Actions, [string] $Ring = 'All')
    $list = @($Actions | Where-Object { $Ring -eq 'All' -or $_.Ring -eq $Ring })
    return @(Sort-Items $list @({ if ($_.Ring -eq 'Production') { 1 } else { 0 } }, { $_.EnvironmentName }, { [string]$_.EnvironmentId },
                                { if ($_.Phase -eq 'FinOps') { 1 } else { 0 } }, { $_.AppName }))
}

function Save-RunPlan {
    param($Plan, [string] $Path)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop }
    $Plan | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding utf8 -ErrorAction Stop
}

function Read-RunPlan {
    <#
    .SYNOPSIS
        Loads plan.json. Throws when it is missing, unreadable, or written by
        an incompatible version.
    #>
    param([string] $Path, [string] $TenantId)
    if (-not $Path -or -not (Test-Path $Path)) { throw "Plan file not found: '$Path'. Run with -Mode Plan first and pass its plan.json." }
    try { $p = Get-Content -Path $Path -Raw | ConvertFrom-Json -Depth 30 }
    catch { throw "Plan file '$Path' is not valid JSON: $(Get-ErrorText $_)" }
    if ($p.schema -ne $script:PlanSchema) { throw "Plan file '$Path' has schema '$($p.schema)', expected '$($script:PlanSchema)'. Re-run the plan with this version." }
    if ($TenantId -and $p.tenantId -and $p.tenantId -ne $TenantId) { throw "Plan file '$Path' was made for tenant '$($p.tenantId)', not '$TenantId'." }
    if ($null -eq $p.actions) { $p | Add-Member -NotePropertyName actions -NotePropertyValue @() -Force }
    return $p
}
