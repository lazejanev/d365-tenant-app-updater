# Entry point.

function Write-CollectedEnvironments {
    # Per environment, A to Z: what was found and decided.
    param($Settings, $Collected, $Decisions)
    foreach ($st in $Collected.AppStates) {
        $e = $st.Env
        Write-Section "ENVIRONMENT: $($e.DisplayName) [$($e.Ring)]"
        Write-Line "ID: $($e.Id)"
        if ($st.PackagesError) { Write-RunWarning "$($e.DisplayName): could not list app packages: $($st.PackagesError)"; continue }
        if ($st.FinOpsMarker) { Write-Line 'Finance and Operations detected (reported in the Finance and Operations section).' }
        if ($st.SolutionsError) { Write-RunWarning "$($e.DisplayName): could not read installed solutions; apps skipped (nothing is installed blindly): $($st.SolutionsError)"; continue }
        $d = @($Decisions | Where-Object { $_.Phase -eq 'Apps' -and $_.EnvironmentId -eq $e.Id })
        $acts = @($d | Where-Object Outcome -eq 'Action')
        $held = @($d | Where-Object Code -eq 'HeldForProduction')
        Write-Line ("Apps evaluated: {0} | updates: {1} | up to date: {2} | held for production: {3} | excluded: {4} | no matching solution: {5}" -f (Get-Count $d), (Get-Count $acts), (Get-Count @($d | Where-Object Code -eq 'UpToDate')), (Get-Count $held), (Get-Count @($d | Where-Object Code -eq 'Excluded')), (Get-Count @($d | Where-Object Code -eq 'NoSolutionMatch')))
        foreach ($a in $acts) {
            $verb = 'Update'
            if ($a.Kind -eq 'AppRetry') { $verb = 'Retry failed install' }
            $line = "  $verb`: $($a.AppName)  $($a.From) -> $($a.To)"
            if ($a.Reason) { $line += "  ($($a.Reason))" }
            Write-Line $line
        }
        foreach ($h in $held) { Write-Line "  Held: $($h.AppName)  $($h.From) -> $($h.To)  ($($h.Reason))" }
        if ($Settings.DumpDiagnostics) {
            $nm = @($d | Where-Object Code -eq 'NoSolutionMatch')
            if ((Get-Count $nm) -gt 0) {
                Start-Group 'Apps with no matching managed solution (not evaluated)'
                foreach ($n in $nm) { Write-Line "  - $($n.AppName) [$($n.AppUniqueName)] available $($n.To)" }
                Stop-Group
            }
        }
    }

    if ((Get-Count $Collected.FinOpsStates) -eq 0) { return }
    Write-Section 'FINANCE AND OPERATIONS'
    if ($Collected.ReleaseMap -and -not $Collected.ReleaseMap.ScheduleError) {
        Write-Line "Release map from Microsoft's PQU schedule ($($Collected.ReleaseMap.Rows) PQU rows): $($Collected.ReleaseMap.Label)"
    }
    if ($Settings.FinOpsApplyVersion) {
        $tgt = '(highest matching scope)'
        if ($Settings.FinOpsTargetVersion) { $tgt = $Settings.FinOpsTargetVersion }
        Write-Line "Apply enabled | scope: $($Settings.FinOpsUpdateScope) | target: $tgt"
        Write-Line 'The current release train is read from the live application build, never from the Anchor Solution. A version on a lower train is never applied.'
    }
    else { Write-Line 'Inventory only (set finOpsApplyVersion = true to enable apply).' }
    if ($Settings.FinOpsApplyVersion) {
        Write-RunWarning "finOpsApplyVersion is true: Finance and Operations versions will be APPLIED to eligible environments (scope $($Settings.FinOpsUpdateScope)). This changes environments and takes hours per environment."
    }
    foreach ($d in @($Decisions | Where-Object Phase -eq 'FinOps')) {
        $line = "$($d.EnvironmentName) [$($d.Ring)]: $($d.From)"
        if ($d.Outcome -eq 'Action') {
            $line += " -> $($d.To) [$($d.TargetStage)]"
            if ($d.Reason) { $line += " ($($d.Reason))" }
        }
        else { $line += " - $($d.Reason)" }
        if ($d.Outcome -eq 'Error') { Write-RunWarning $line } else { Write-Line $line }
    }
}

function Invoke-D365TenantAppUpdate {
    <#
    .SYNOPSIS
        Keeps Dynamics 365 apps and Finance and Operations versions current
        across every environment of a tenant.

    .DESCRIPTION
        Collect -> plan -> apply -> wait -> report.
          -Mode PlanAndApply (default): plan and apply in one run (v2 behaviour).
          -Mode Plan:  write plan.json and the reports, change nothing.
          -Mode Apply: read plan.json (-PlanFile), re-check every action
                       against the live tenant, and apply the -Ring given.
        Every setting can also come from an environment variable with the
        same name (Azure DevOps variable group, GitHub repository variables).
        Returns the process exit code (0 or 1).
    #>
    [CmdletBinding()]
    param(
        [string] $ClientId = '',
        [string] $ClientSecret = '',
        [string] $TenantId = '',
        [ValidateSet('PlanAndApply', 'Plan', 'Apply')] [string] $Mode = 'PlanAndApply',
        [ValidateSet('All', 'NonProduction', 'Production')] [string] $Ring = 'All',
        [string] $PlanFile = '',
        [string] $OutputDirectory = '',
        [hashtable] $Setting = @{}
    )

    $version = Get-D365TenantAppUpdaterVersion
    $bound = @{}
    foreach ($k in $Setting.Keys) { $bound[$k] = [string]$Setting[$k] }
    # Sign-in identity: parameter, then D365_* variable, then (Azure DevOps
    # federated pipeline) the identity of the service connection.
    $pick = { param($a, $b, $c) foreach ($v in @($a, $b, $c)) { if (-not (Test-Unset $v)) { return [string]$v } }; return '' }
    $bound['ClientId'] = & $pick $ClientId $env:D365_CLIENT_ID $env:AZURESUBSCRIPTION_CLIENT_ID
    $bound['ClientSecret'] = & $pick $ClientSecret $env:D365_CLIENT_SECRET ''
    $bound['TenantId'] = & $pick $TenantId $env:D365_TENANT_ID $env:AZURESUBSCRIPTION_TENANT_ID

    $settings = Get-RunSettings -Bound $bound
    if (-not $OutputDirectory) { $OutputDirectory = Get-DefaultOutputDirectory }
    if (-not $PlanFile) { $PlanFile = Join-Path $OutputDirectory 'plan.json' }

    $effectiveMode = $Mode
    if ($Mode -eq 'PlanAndApply' -and $settings.PlanOnly) { $effectiveMode = 'Plan' }
    Write-EffectiveSettings -Settings $settings -Version $version -Mode $effectiveMode -Ring $Ring

    $context = [pscustomobject]@{
        Version = $version; Mode = $effectiveMode; Ring = $Ring; OutputDirectory = $OutputDirectory; PlanFile = $PlanFile
        Environments = @(); AppStates = @(); FinOpsStates = @(); Decisions = @(); Actions = @(); Results = @()
        Applied = $false; Errors = @(); Warnings = @($settings.Warnings); CountPlanErrors = $true
    }

    # ---------- sign-in ----------
    if ((Test-Unset $settings.ClientId) -or (Test-Unset $settings.TenantId)) {
        Write-RunError 'ClientId and TenantId are required (parameters, or D365_CLIENT_ID / D365_TENANT_ID).'
        return (Complete-Run -Result 'Failed')
    }
    try {
        $auth = Initialize-Auth -Settings $settings
        $how = $auth.Mode
        if ($auth.Source) { $how += " ($($auth.Source) OIDC)" }
        Write-Line ("  {0,-27}: {1}" -f 'Sign-in', $how)
        if ($auth.Mode -eq 'Federated' -and $settings.UsePacFallback) {
            $settings.UsePacFallback = $false
            $w = 'usePacFallback is ignored with federated sign-in (the PAC CLI fallback needs a client secret). Apps that need a custom install are reported for the admin center instead.'
            Write-RunWarning $w; $context.Warnings += $w
        }
        $null = Get-AccessToken -Settings $settings -Scope $settings.BapScope
    }
    catch {
        Write-RunError (Get-ErrorText $_)
        return (Complete-Run -Result 'Failed')
    }

    # ---------- Apply from a plan file ----------
    if ($effectiveMode -eq 'Apply') {
        try { $plan = Read-RunPlan -Path $PlanFile -TenantId $settings.TenantId }
        catch { Write-RunError (Get-ErrorText $_); return (Complete-Run -Result 'Failed') }
        Write-Line ("  {0,-27}: {1} (made {2} by {3})" -f 'Plan file', $PlanFile, $plan.createdUtc, $plan.toolVersion)
        $context.Environments = @($plan.environments)
        $context.Decisions = @($plan.decisions)
        # Plan-time read errors were already reported (and counted) by the
        # Plan stage; an Apply stage judges only its own actions.
        $context.CountPlanErrors = $false
        $context.Actions = @($plan.actions | Where-Object { $Ring -eq 'All' -or $_.Ring -eq $Ring })
        $urls = @{}
        foreach ($e in @($plan.environments)) { $urls[[string]$e.Id] = [string]$e.InstanceUrl }
        $ordered = Get-OrderedActions -Actions $context.Actions -Ring $Ring
        # The settings may have changed since the plan (an admin excluding an
        # environment, or turning F&O apply off, while production waited for
        # approval). Actions the current settings no longer allow are stopped.
        $gate = Split-AllowedActions -Settings $settings -Actions $ordered -Plan $plan
        Write-Section "APPLY: $((Get-Count $gate.Allowed)) action(s), ring $Ring"
        foreach ($st in $gate.Stopped) { Write-Line "  $($st.EnvironmentName): $($st.AppName) $($st.To) - stopped ($($st.Detail))" }
        $context.Results = @($gate.Stopped) + @(Invoke-PlanActions -Settings $settings -Actions $gate.Allowed -Revalidate $true -DryRun $settings.PlanOnly -InstanceUrls $urls)
        $context.Applied = $true
        if (-not $settings.PlanOnly) { Wait-AppOperations -Settings $settings -Results $context.Results }
        $result = Write-RunReport -Settings $settings -Context $context
        return (Complete-Run -Result $result -FailOnIssues $settings.FailOnIssues)
    }

    # ---------- Collect and plan ----------
    try { $discovery = Get-TenantEnvironments -Settings $settings }
    catch { Write-RunError (Get-ErrorText $_); return (Complete-Run -Result 'Failed') }
    Write-Section 'ENVIRONMENTS (A–Z)'
    Write-Line "Dataverse environments: $((Get-Count $discovery.All)) | in scope: $((Get-Count $discovery.InScope)) | excluded: $((Get-Count $discovery.Excluded)) | without Dataverse (skipped): $($discovery.NoDataverse)"
    foreach ($e in $discovery.InScope) { Write-Line ("  {0,-40} {1,-14} {2}" -f $e.DisplayName, $e.Ring, $e.Sku) }
    foreach ($e in $discovery.Excluded) { Write-Line ("  {0,-40} excluded" -f $e.DisplayName) }
    foreach ($w in @($discovery.Warnings)) { Write-RunWarning $w; $context.Warnings += $w }

    $collected = Invoke-Collect -Settings $settings -Discovery $discovery
    $planned = New-RunPlan -Settings $settings -Collected $collected -Version $version
    $plan = $planned.Plan
    $context.Environments = @($discovery.InScope)
    $context.AppStates = @($collected.AppStates)
    $context.FinOpsStates = @($collected.FinOpsStates)
    $context.Decisions = @($plan.decisions)
    $context.Actions = @($plan.actions)
    $context.Errors = @($collected.Errors)
    foreach ($w in @($collected.Warnings) + @($planned.Warnings)) { Write-RunWarning $w; $context.Warnings += $w }

    Write-CollectedEnvironments -Settings $settings -Collected $collected -Decisions (@($plan.actions) + @($plan.decisions))

    $planSaved = $false
    try {
        Save-RunPlan -Plan $plan -Path $PlanFile
        $planSaved = $true
        Write-Line ''
        Write-Line "Plan written: $PlanFile"
    }
    catch {
        $msg = "Could not write the plan file '$PlanFile': $(Get-ErrorText $_)"
        if ($effectiveMode -eq 'Plan') { Write-RunError $msg } else { Write-RunWarning $msg }
    }
    if ($planSaved) {
        $nonProd = Get-Count @($plan.actions | Where-Object Ring -eq 'NonProduction')
        $prod = Get-Count @($plan.actions | Where-Object Ring -eq 'Production')
        Set-RunOutput -Name 'hasNonProductionActions' -Value ([string]($nonProd -gt 0)).ToLowerInvariant()
        Set-RunOutput -Name 'hasProductionActions' -Value ([string]($prod -gt 0)).ToLowerInvariant()
        Set-RunOutput -Name 'planFile' -Value $PlanFile
    }

    if ($effectiveMode -eq 'PlanAndApply') {
        $ordered = Get-OrderedActions -Actions $plan.actions -Ring $Ring
        Write-Section "APPLY: $((Get-Count $ordered)) action(s), ring $Ring"
        $context.Results = @(Invoke-PlanActions -Settings $settings -Actions $ordered -Revalidate $false -DryRun $false)
        $context.Applied = $true
        Wait-AppOperations -Settings $settings -Results $context.Results
    }

    $result = Write-RunReport -Settings $settings -Context $context
    # A Plan run whose plan could not be written cannot feed the Apply stages.
    if ($effectiveMode -eq 'Plan' -and -not $planSaved) { return (Complete-Run -Result 'Failed') }
    # failOnIssues never fails the Plan stage: that would skip every apply in
    # the tenant because one environment could not be read. The issues are
    # reported by Plan and fail the run where the changes happen.
    $failOnIssues = $settings.FailOnIssues -and $effectiveMode -ne 'Plan'
    return (Complete-Run -Result $result -FailOnIssues $failOnIssues)
}
