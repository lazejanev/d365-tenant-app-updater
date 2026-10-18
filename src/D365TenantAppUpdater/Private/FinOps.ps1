# Phase 2: Finance and Operations version updates.
#
# Collect: for every environment where the F&O provisioning app is installed
# (presence only, the Anchor Solution's version is never used), read the
# live build (finopsproperties), the versions Microsoft offers
# (finopsversions) and the maintenance window (finopsadminsettings).
# Plan: pick the target per finOpsUpdateScope, never a lower train, and in
# production only a version a non-production environment already runs.

function Get-FinOpsReleaseMap {
    <#
    .SYNOPSIS
        Build -> release train map: Microsoft's PQU schedule (downloaded every
        run), the built-in fallback and the optional finOpsBuildTrainMap
        override. Returns { Map; Label; ScheduleError; Rows; Ambiguous; Invalid }.
    #>
    param($Settings)
    $sched = Get-FinOpsScheduleMap -Url $Settings.FinOpsScheduleUrl
    $r = ConvertTo-FinOpsBuildTrainMap -BuiltIn $script:FinOpsBuildTrainBuiltIn -Extra $Settings.FinOpsBuildTrainMap -Schedule $sched.Map -Ambiguous $sched.Ambiguous
    $label = @($r.Map.Keys | Sort-Object { [int](($_ -split '\.')[2]) } | ForEach-Object { '10.0.' + $r.Map[$_] + ' = ' + $_ + '.x' }) -join ', '
    return [pscustomobject]@{ Map = $r.Map; Label = $label; ScheduleError = $sched.Error; Rows = $sched.Rows; Ambiguous = @($sched.Ambiguous); Invalid = @($r.Invalid) }
}

function Test-FinOpsDeploymentEligible {
    param($Settings, [AllowEmptyString()] [string] $DeploymentType)
    if ((Get-Count $Settings.FinOpsDeploymentTypes) -eq 0) { return $true }
    foreach ($dt in $Settings.FinOpsDeploymentTypes) { if ($DeploymentType -ieq [string]$dt) { return $true } }
    return $false
}

function Get-FinOpsEnvironmentState {
    <#
    .SYNOPSIS
        Collects one F&O environment. Never throws; failures are recorded.
    #>
    param($Settings, $EnvObj, [hashtable] $TrainMap)
    $s = [pscustomobject]@{
        Env = $EnvObj
        PropsError = ''; AppVersion = ''; PlatformVersion = ''; DeploymentType = ''; Aos = ''; BatchAos = ''
        Train = $null; Prefix = ''
        Eligible = $false
        VersionsRead = $false; VersionsError = ''; VersionsRouteMissing = $false; Versions = @()
        MaintenanceCadence = ''; MaintenanceDays = ''
    }
    $pr = Invoke-Http -Method 'GET' -Uri (New-FinOpsUri -Settings $Settings -EnvironmentId $EnvObj.Id -Leaf 'finopsproperties') -Headers (Get-PpHeaders $Settings)
    if (-not (Test-HttpOk $pr)) { $s.PropsError = Format-RestFailure $pr; return $s }
    $j = $pr.Json
    if ($j) {
        if ($j.applicationVersion) { $s.AppVersion = [string]$j.applicationVersion }
        if ($j.platformVersion) { $s.PlatformVersion = [string]$j.platformVersion }
        if ($j.deploymentType) { $s.DeploymentType = [string]$j.deploymentType }
        if ($null -ne $j.lastObservedAOSCount -and $j.maxAOSCount) { $s.Aos = "$($j.lastObservedAOSCount) / $($j.maxAOSCount)" }
        if ($null -ne $j.lastObservedBatchAOSCount -and $j.maxBatchAOSCount) { $s.BatchAos = "$($j.lastObservedBatchAOSCount) / $($j.maxBatchAOSCount)" }
    }
    $live = Get-FinOpsLiveTrain -AppVersion $s.AppVersion -Map $TrainMap
    $s.Train = $live.Train
    $s.Prefix = $live.Prefix
    $s.Eligible = Test-FinOpsDeploymentEligible -Settings $Settings -DeploymentType $s.DeploymentType

    # Maintenance window: informational only. Failure is not an issue.
    try {
        $mr = Invoke-Http -Method 'GET' -Uri (New-FinOpsUri -Settings $Settings -EnvironmentId $EnvObj.Id -Leaf 'finopsadminsettings') -Headers (Get-PpHeaders $Settings)
        if ((Test-HttpOk $mr) -and $mr.Json) {
            if ($mr.Json.PSObject.Properties['maintenanceWindowCadence'] -and $mr.Json.maintenanceWindowCadence) { $s.MaintenanceCadence = [string]$mr.Json.maintenanceWindowCadence }
            if ($mr.Json.PSObject.Properties['maintenanceWindowDaysOfWeek'] -and $mr.Json.maintenanceWindowDaysOfWeek) { $s.MaintenanceDays = (@($mr.Json.maintenanceWindowDaysOfWeek) | ForEach-Object { [string]$_ }) -join ', ' }
        }
    }
    catch { $null = $_ }

    if (-not $s.Eligible) { return $s }
    $vr = Invoke-Http -Method 'GET' -Uri (New-FinOpsUri -Settings $Settings -EnvironmentId $EnvObj.Id -Leaf 'finopsversions') -Headers (Get-PpHeaders $Settings)
    if (-not (Test-HttpOk $vr)) {
        if (-not $vr.Transport -and (Get-ApiErrorCode $vr) -eq 'RouteNotFound') { $s.VersionsRouteMissing = $true }
        else { $s.VersionsError = Format-RestFailure $vr }
        return $s
    }
    $s.VersionsRead = $true
    $s.Versions = @(ConvertTo-FinOpsVersionList -Json $vr.Json)
    return $s
}

function Format-FinOpsCurrent {
    param($State)
    if ($null -ne $State.Train) { return "$($State.AppVersion) [10.0.$($State.Train)]" }
    return $State.AppVersion
}

function New-FinOpsDecision {
    param($State, [string] $Outcome, [string] $Code, [string] $Reason, [string] $To = '', [string] $Stage = '')
    return [pscustomobject]@{
        Phase = 'FinOps'; Kind = 'FinOpsApply'; Outcome = $Outcome; Code = $Code; Reason = $Reason
        EnvironmentId = $State.Env.Id; EnvironmentName = $State.Env.DisplayName; Ring = $State.Env.Ring
        AppUniqueName = ''; AppName = 'Finance and Operations'
        From = (Format-FinOpsCurrent $State); To = $To; TargetStage = $Stage; Package = $null
    }
}

function Select-FinOpsTarget {
    <#
    .SYNOPSIS
        v2.4.4 target rules, unchanged:
          QualityUpdate - releaseStage QualityUpdate on the SAME train.
          VersionUpdate - the NEXT train only, released stages only.
          Any           - anything offered.
        A version on a lower train than the live build is never chosen.
        Returns { Target; Stage; Code; Reason } (Target empty = skip).
    #>
    param($Settings, $State)
    $available = @($State.Versions)
    $cur = $State.Train
    $scope = $Settings.FinOpsUpdateScope
    $availLabel = (($available | ForEach-Object { "$($_.Version) [$($_.ReleaseStage)]" }) -join ', ')
    $skip = { param($c, $r) [pscustomobject]@{ Target = ''; Stage = ''; Code = $c; Reason = $r } }

    if ((Get-Count $available) -eq 0) { return (& $skip 'NoVersions' 'no newer version offered') }

    $scoped = $available
    if ($scope -ne 'Any') {
        if ($null -eq $cur) {
            $why = 'no application version reported'
            if ($State.Prefix) { $why = "build $($State.Prefix).x is not in Microsoft's PQU schedule or the built-in map yet" }
            return (& $skip 'TrainUnknown' "current release train unknown ($why); apply skipped (fail-safe). Offered: $availLabel")
        }
        if ($scope -eq 'QualityUpdate') {
            $scoped = @($available | Where-Object { $_.ReleaseStage -ieq 'QualityUpdate' -and (Get-FinOpsTrain $_.Version) -eq $cur })
        }
        else {
            $scoped = @($available | Where-Object { $t = Get-FinOpsTrain $_.Version; ($null -ne $t) -and $t -eq ($cur + 1) -and ($script:FinOpsReleasedStages -contains [string]$_.ReleaseStage) })
        }
    }
    if ($null -ne $cur) {
        $scoped = @($scoped | Where-Object { $t = Get-FinOpsTrain $_.Version; ($null -eq $t) -or $t -ge $cur })
    }

    $requested = [string]$Settings.FinOpsTargetVersion
    if ($requested) {
        $match = $available | Where-Object { $_.Version -eq $requested } | Select-Object -First 1
        if (-not $match) { return (& $skip 'TargetNotOffered' "requested '$requested' is not offered. Offered: $availLabel") }
        $tt = Get-FinOpsTrain $requested
        if ($null -ne $cur -and $null -ne $tt -and $tt -lt $cur) { return (& $skip 'LowerTrain' "requested '$requested' is on a lower train than 10.0.$cur") }
        if ($scope -ne 'Any' -and (@($scoped | ForEach-Object { $_.Version }) -notcontains $requested)) {
            return (& $skip 'OutOfScope' "requested '$requested' [$($match.ReleaseStage)] is not a $(Get-FinOpsScopeLabel $scope) for 10.0.$cur")
        }
        return [pscustomobject]@{ Target = $requested; Stage = [string]$match.ReleaseStage; Code = ''; Reason = '' }
    }

    if ((Get-Count $scoped) -eq 0) {
        $what = "$(Get-FinOpsScopeLabel $scope) version"
        if ($scope -eq 'VersionUpdate') { $what = 'version update (next train)' }
        $trainText = 'the current train'
        if ($null -ne $cur) { $trainText = "10.0.$cur" }
        return (& $skip 'OutOfScope' "no $what available for $trainText. Offered: $availLabel")
    }
    $target = Select-HighestVersion -Versions ($scoped | ForEach-Object { $_.Version })
    $m = $available | Where-Object { $_.Version -eq $target } | Select-Object -First 1
    return [pscustomobject]@{ Target = $target; Stage = [string]$m.ReleaseStage; Code = ''; Reason = '' }
}

function Test-FinOpsProven {
    <#
    .SYNOPSIS
        Production ring rule for F&O. A non-production F&O environment proves
        a target when it already runs it or later:
          - its live train is higher than the target's train, or
          - its live train equals the target's train and the target is NOT
            in its offered list (Microsoft offers only versions later than
            the installed one, so it already has it).
        Data for every environment is collected before planning, so the
        check is independent of alphabetical order.
    #>
    param($States, [string] $Target)
    $tt = Get-FinOpsTrain $Target
    if ($null -eq $tt) { return [pscustomobject]@{ Proven = $false; By = ''; Reason = "train of '$Target' unknown" } }
    $candidates = 0
    foreach ($s in $States) {
        if ($s.Env.Ring -ne 'NonProduction' -or $s.PropsError -or $null -eq $s.Train) { continue }
        $candidates++
        if ($s.Train -gt $tt) { return [pscustomobject]@{ Proven = $true; By = $s.Env.DisplayName; Reason = '' } }
        if ($s.Train -eq $tt -and $s.VersionsRead -and (@($s.Versions | ForEach-Object { $_.Version }) -notcontains $Target)) {
            return [pscustomobject]@{ Proven = $true; By = $s.Env.DisplayName; Reason = '' }
        }
    }
    if ($candidates -eq 0) { return [pscustomobject]@{ Proven = $false; By = ''; Reason = 'no non-production F&O environment in scope to prove it' } }
    return [pscustomobject]@{ Proven = $false; By = ''; Reason = "no non-production F&O environment runs $Target yet" }
}

function New-FinOpsPlan {
    param($Settings, $States)
    $decisions = @()
    foreach ($s in $States) {
        if ($s.PropsError) { $decisions += New-FinOpsDecision -State $s -Outcome 'Error' -Code 'PropertiesFailed' -Reason "properties unavailable: $($s.PropsError)"; continue }
        if (-not $Settings.FinOpsApplyVersion) { $decisions += New-FinOpsDecision -State $s -Outcome 'Skip' -Code 'InventoryOnly' -Reason 'inventory only (finOpsApplyVersion = false)'; continue }
        if (-not $s.Eligible) {
            $why = 'deployment type not eligible'
            if ($s.DeploymentType -like 'LCS*') { $why = 'LCS managed' }
            $decisions += New-FinOpsDecision -State $s -Outcome 'Skip' -Code 'NotEligible' -Reason "$why ($($s.DeploymentType))"
            continue
        }
        if ($s.VersionsRouteMissing) { $decisions += New-FinOpsDecision -State $s -Outcome 'Skip' -Code 'RouteNotFound' -Reason 'versions route unavailable (RouteNotFound)'; continue }
        if ($s.VersionsError) { $decisions += New-FinOpsDecision -State $s -Outcome 'Error' -Code 'VersionsFailed' -Reason "versions lookup failed: $($s.VersionsError)"; continue }

        $sel = Select-FinOpsTarget -Settings $Settings -State $s
        if (-not $sel.Target) {
            $outcome = 'Skip'
            if ($sel.Code -eq 'TargetNotOffered') { $outcome = 'Error' }
            $decisions += New-FinOpsDecision -State $s -Outcome $outcome -Code $sel.Code -Reason $sel.Reason
            continue
        }
        if ($Settings.ProductionRing -and $s.Env.Ring -eq 'Production') {
            $pr = Test-FinOpsProven -States $States -Target $sel.Target
            if (-not $pr.Proven) {
                $decisions += New-FinOpsDecision -State $s -Outcome 'Skip' -Code 'HeldForProduction' -Reason "held for production: $($pr.Reason)" -To $sel.Target -Stage $sel.Stage
                continue
            }
            $decisions += New-FinOpsDecision -State $s -Outcome 'Action' -Code 'Proven' -Reason "already runs in $($pr.By)" -To $sel.Target -Stage $sel.Stage
            continue
        }
        $decisions += New-FinOpsDecision -State $s -Outcome 'Action' -Code '' -Reason '' -To $sel.Target -Stage $sel.Stage
    }
    return $decisions
}

function Get-FinOpsInventoryRows {
    param($States)
    $rows = @()
    foreach ($s in $States) {
        $train = ''
        if ($null -ne $s.Train) { $train = "10.0.$($s.Train)" }
        $offered = ''
        if ($s.VersionsRead) { $offered = (($s.Versions | ForEach-Object { "$($_.Version) [$($_.ReleaseStage)]" }) -join ', ') }
        $rows += [pscustomobject]@{
            Environment = $s.Env.DisplayName; EnvironmentId = $s.Env.Id; Ring = $s.Env.Ring
            Application = $s.AppVersion; Train = $train; Platform = $s.PlatformVersion; Deployment = $s.DeploymentType
            AOS = $s.Aos; BatchAOS = $s.BatchAos
            MaintenanceCadence = $s.MaintenanceCadence; MaintenanceDays = $s.MaintenanceDays
            Offered = $offered
        }
    }
    return @($rows | Sort-Object { Get-SortKey $_.Environment }, EnvironmentId)
}
