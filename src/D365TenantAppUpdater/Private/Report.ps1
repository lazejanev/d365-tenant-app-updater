# Reporting: console summary, summary.md (shown on the run page of both
# platforms) and report.json (machine readable). Every list is A to Z by
# environment name.

function ConvertTo-MdCell {
    param([AllowNull()] $Value)
    $t = [string]$Value
    if ($t -eq '') { return ' ' }
    return ($t -replace '\|', '\|' -replace "`r?`n", ' ')
}

function ConvertTo-MdTable {
    param([string[]] $Headers, $Rows, [scriptblock[]] $Cells)
    $out = @()
    $out += '| ' + ($Headers -join ' | ') + ' |'
    $out += '|' + (($Headers | ForEach-Object { ' --- ' }) -join '|') + '|'
    foreach ($r in $Rows) {
        $vals = foreach ($c in $Cells) { ConvertTo-MdCell (& $c $r) }
        $out += '| ' + ($vals -join ' | ') + ' |'
    }
    return $out
}

function Sort-ByEnvironment {
    param($Items)
    return @($Items | Sort-Object @{ Expression = { Get-SortKey $_.EnvironmentName } }, @{ Expression = { $_.EnvironmentId } }, @{ Expression = { if ($_.Phase -eq 'FinOps') { 1 } else { 0 } } }, @{ Expression = { Get-SortKey $_.AppName } })
}

function Get-EnvironmentRows {
    # One row per environment in scope: what was found and decided.
    param($Context)
    $rows = @()
    foreach ($e in (Sort-ByDisplayName $Context.Environments)) {
        $d = @($Context.Decisions | Where-Object { $_.EnvironmentId -eq $e.Id -and $_.Phase -eq 'Apps' })
        $a = @($Context.Actions | Where-Object { $_.EnvironmentId -eq $e.Id -and $_.Phase -eq 'Apps' })
        $st = $null
        if ($Context.AppStates) { $st = $Context.AppStates | Where-Object { $_.Env.Id -eq $e.Id } | Select-Object -First 1 }
        $status = 'ok'
        if ($st -and $st.PackagesError) { $status = 'packages unavailable' }
        elseif ($st -and $st.SolutionsError) { $status = 'solutions unavailable' }
        $fo = ''
        if ($st -and $st.FinOpsMarker) { $fo = 'yes' }
        $rows += [pscustomobject]@{
            Environment = $e.DisplayName; EnvironmentId = $e.Id; Ring = $e.Ring; Type = $e.Sku
            Updates = (Get-Count $a)
            UpToDate = (Get-Count @($d | Where-Object Code -eq 'UpToDate'))
            Held = (Get-Count @($d | Where-Object Code -eq 'HeldForProduction'))
            Excluded = (Get-Count @($d | Where-Object Code -eq 'Excluded'))
            NoMatch = (Get-Count @($d | Where-Object Code -eq 'NoSolutionMatch'))
            FinOps = $fo; Status = $status
        }
    }
    return $rows
}

function Get-RunResult {
    <#
    .SYNOPSIS
        Succeeded, or SucceededWithIssues when something could not be read
        or an action failed. (Failed is decided earlier: sign-in, discovery,
        a broken plan file.)
    #>
    param($Context)
    $failedResults = @($Context.Results | Where-Object { $_.Result -eq 'Failed' })
    $errorDecisions = @()
    if ($Context.CountPlanErrors) { $errorDecisions = @($Context.Decisions | Where-Object { $_.Outcome -eq 'Error' }) }
    if ((Get-Count $Context.Errors) -gt 0 -or (Get-Count $failedResults) -gt 0 -or (Get-Count $errorDecisions) -gt 0) { return 'SucceededWithIssues' }
    return 'Succeeded'
}

function Write-RunReport {
    <#
    .SYNOPSIS
        Writes summary.md and report.json to the output directory, prints the
        console summary and publishes the summary to the run page.
        Returns the run result.
    #>
    param($Settings, $Context)
    $result = Get-RunResult -Context $Context
    $dir = $Context.OutputDirectory
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $actions = Sort-ByEnvironment $Context.Actions
    $results = Sort-ByEnvironment $Context.Results
    $held = Sort-ByEnvironment @($Context.Decisions | Where-Object Code -eq 'HeldForProduction')
    $attentionDecisions = Sort-ByEnvironment @($Context.Decisions | Where-Object { $_.Outcome -eq 'Error' })
    $attentionResults = Sort-ByEnvironment @($Context.Results | Where-Object { $_.Result -in @('Failed', 'Manual', 'AdminMode', 'TimedOut', 'Stale', 'Stopped') })
    $foSkips = Sort-ByEnvironment @($Context.Decisions | Where-Object { $_.Phase -eq 'FinOps' -and $_.Outcome -eq 'Skip' -and $_.Code -ne 'HeldForProduction' })
    $envRows = @(Get-EnvironmentRows -Context $Context)
    $foRows = @()
    if ($Context.FinOpsStates) { $foRows = @(Get-FinOpsInventoryRows -States $Context.FinOpsStates) }

    # ---------------- console ----------------
    Write-Section 'SUMMARY'
    Write-Line ("  {0,-34}: {1}" -f 'Result', $result)
    Write-Line ("  {0,-34}: {1}" -f 'Mode / ring', "$($Context.Mode) / $($Context.Ring)")
    Write-Line ("  {0,-34}: {1}" -f 'Environments in scope', (Get-Count $Context.Environments))
    Write-Line ("  {0,-34}: {1}" -f 'Planned actions', (Get-Count $actions))
    Write-Line ("  {0,-34}: {1}" -f 'Held for production', (Get-Count $held))
    if ($Context.Applied) {
        foreach ($k in @('Succeeded', 'Started', 'AlreadyDone', 'TimedOut', 'Stale', 'Stopped', 'Manual', 'AdminMode', 'Failed', 'WouldApply')) {
            $n = Get-Count @($results | Where-Object Result -eq $k)
            if ($n -gt 0) { Write-Line ("  {0,-34}: {1}" -f "Results: $k", $n) }
        }
    }
    if ((Get-Count $Context.Errors) -gt 0) {
        Start-Group "Could not be read ($((Get-Count $Context.Errors)))"
        foreach ($e in $Context.Errors) { Write-Line "  - $e" }
        Stop-Group
    }
    if ((Get-Count $foRows) -gt 0) {
        Start-Group 'Finance and Operations inventory'
        Write-Line (($foRows | Format-Table Environment, Ring, Application, Train, Deployment, AOS, MaintenanceCadence, MaintenanceDays -AutoSize | Out-String -Width 220).TrimEnd())
        Stop-Group
    }

    # ---------------- summary.md ----------------
    $md = @()
    $md += "## d365-tenant-app-updater $($Context.Version)"
    $md += ''
    $md += "**Result:** $result &nbsp;·&nbsp; **Mode:** $($Context.Mode) &nbsp;·&nbsp; **Ring:** $($Context.Ring) &nbsp;·&nbsp; **Host:** $(Get-HostKind) &nbsp;·&nbsp; $((Get-Now).ToString('yyyy-MM-dd HH:mm')) UTC"
    if ($Settings.PlanOnly) { $md += ''; $md += '> whatIf is on: nothing was changed.' }
    $md += ''
    $md += "Environments in scope: **$((Get-Count $Context.Environments))** · planned actions: **$((Get-Count $actions))** · held for production: **$((Get-Count $held))**"
    $md += ''

    if ($Context.Applied -and (Get-Count $results) -gt 0) {
        $md += '### Results'
        $md += ConvertTo-MdTable -Headers @('Environment', 'Ring', 'App', 'From', 'To', 'Result', 'Detail') -Rows $results -Cells @({ $args[0].EnvironmentName }, { $args[0].Ring }, { $args[0].AppName }, { $args[0].From }, { $args[0].To }, { $args[0].Result }, { $args[0].Detail })
        $md += ''
    }
    elseif ((Get-Count $actions) -gt 0) {
        $md += '### Planned'
        $md += ConvertTo-MdTable -Headers @('Environment', 'Ring', 'App', 'From', 'To', 'Note') -Rows $actions -Cells @({ $args[0].EnvironmentName }, { $args[0].Ring }, { $args[0].AppName }, { $args[0].From }, { $args[0].To }, { $args[0].Reason })
        $md += ''
    }
    if ((Get-Count $held) -gt 0) {
        $md += '### Held for production'
        $md += 'Production takes a version only after a non-production environment runs it (productionRing = true).'
        $md += ''
        $md += ConvertTo-MdTable -Headers @('Environment', 'App', 'From', 'To', 'Why') -Rows $held -Cells @({ $args[0].EnvironmentName }, { $args[0].AppName }, { $args[0].From }, { $args[0].To }, { $args[0].Reason })
        $md += ''
    }
    if ((Get-Count $attentionResults) -gt 0 -or (Get-Count $attentionDecisions) -gt 0 -or (Get-Count $Context.Errors) -gt 0) {
        $md += '### Needs attention'
        foreach ($r in $attentionResults) { $md += "- **$($r.EnvironmentName)** – $($r.AppName) $($r.To): $($r.Result). $($r.Detail)" }
        foreach ($d in $attentionDecisions) { $md += "- **$($d.EnvironmentName)** – $($d.AppName): $($d.Reason)" }
        foreach ($e in $Context.Errors) { $md += "- $e" }
        $md += ''
    }
    if ((Get-Count $envRows) -gt 0) {
        $md += '### Environments (A–Z)'
        $md += ConvertTo-MdTable -Headers @('Environment', 'Ring', 'Updates', 'Up to date', 'Held', 'Excluded', 'No match', 'F&O', 'Status') -Rows $envRows -Cells @({ $args[0].Environment }, { $args[0].Ring }, { $args[0].Updates }, { $args[0].UpToDate }, { $args[0].Held }, { $args[0].Excluded }, { $args[0].NoMatch }, { $args[0].FinOps }, { $args[0].Status })
        $md += ''
    }
    if ((Get-Count $foRows) -gt 0) {
        $md += '### Finance and Operations'
        $md += ConvertTo-MdTable -Headers @('Environment', 'Ring', 'Application', 'Train', 'Deployment', 'Maintenance', 'Offered') -Rows $foRows -Cells @({ $args[0].Environment }, { $args[0].Ring }, { $args[0].Application }, { $args[0].Train }, { $args[0].Deployment }, { (@($args[0].MaintenanceCadence, $args[0].MaintenanceDays) | Where-Object { $_ }) -join ' ' }, { $args[0].Offered })
        if ((Get-Count $foSkips) -gt 0) {
            $md += ''
            foreach ($d in $foSkips) { $md += "- **$($d.EnvironmentName)**: $($d.Reason)" }
        }
        $md += ''
    }
    if ((Get-Count $Context.Warnings) -gt 0) {
        $md += '### Warnings'
        foreach ($w in $Context.Warnings) { $md += "- $w" }
        $md += ''
    }
    $mdPath = Join-Path $dir 'summary.md'
    ($md -join "`n") | Set-Content -Path $mdPath -Encoding utf8

    # ---------------- report.json ----------------
    $report = [ordered]@{
        tool = 'd365-tenant-app-updater'; version = $Context.Version; result = $result
        mode = $Context.Mode; ring = $Context.Ring; host = (Get-HostKind); whatIf = $Settings.PlanOnly
        createdUtc = (Get-Now).ToString('o'); planFile = $Context.PlanFile
        environments = $envRows
        actions = @($actions | Select-Object Phase, Kind, Ring, EnvironmentId, EnvironmentName, AppUniqueName, AppName, From, To, Code, Reason)
        results = $results
        decisions = @(Sort-ByEnvironment $Context.Decisions | Select-Object Phase, Kind, Outcome, Code, Reason, Ring, EnvironmentId, EnvironmentName, AppUniqueName, AppName, From, To)
        finOps = $foRows
        errors = @($Context.Errors); warnings = @($Context.Warnings)
    }
    $report | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $dir 'report.json') -Encoding utf8

    Publish-RunSummary -MarkdownPath $mdPath
    Write-Line ''
    Write-Line "Reports: $mdPath, $(Join-Path $dir 'report.json')"
    return $result
}
