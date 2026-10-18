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
    return @(Sort-Items $Items @({ $_.EnvironmentName }, { [string]$_.EnvironmentId }, { if ($_.Phase -eq 'FinOps') { 1 } else { 0 } }, { $_.AppName }))
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

# One status vocabulary for the log board, summary.md and report.json.
# Tag: fixed-width text in the log (readable without colour).
# Color: log colour (Write-Colored). Icon: run-page summary.
# Group: which overview counter it adds to.
$script:StatusStyle = [ordered]@{
    Updated   = @{ Tag = 'UPDATED'; Color = 'Green';   Icon = '✅'; Group = 'Updated';    Label = 'Updated' }
    Started   = @{ Tag = 'RUNNING'; Color = 'Blue';    Icon = '⏳'; Group = 'InProgress'; Label = 'In progress' }
    TimedOut  = @{ Tag = 'RUNNING'; Color = 'Blue';    Icon = '⏳'; Group = 'InProgress'; Label = 'Still running' }
    Planned   = @{ Tag = 'PLANNED'; Color = 'Blue';    Icon = '🗓️'; Group = 'Planned';    Label = 'Planned' }
    Held      = @{ Tag = 'HELD';    Color = 'Magenta'; Icon = '⏸️'; Group = 'Held';       Label = 'Held for production' }
    Done      = @{ Tag = 'CURRENT'; Color = 'Green';   Icon = '✔️'; Group = 'UpToDate';   Label = 'Already current' }
    Stale     = @{ Tag = 'CHANGED'; Color = 'Yellow';  Icon = '↩️'; Group = 'Attention';  Label = 'Changed since plan' }
    Stopped   = @{ Tag = 'STOPPED'; Color = 'Yellow';  Icon = '⛔'; Group = 'Attention';  Label = 'Stopped by settings' }
    Manual    = @{ Tag = 'MANUAL';  Color = 'Yellow';  Icon = '🖐️'; Group = 'Attention';  Label = 'Install in admin center' }
    AdminMode = @{ Tag = 'ADMIN';   Color = 'Yellow';  Icon = '⚠️'; Group = 'Attention';  Label = 'Admin mode' }
    Failed    = @{ Tag = 'FAILED';  Color = 'Red';     Icon = '❌'; Group = 'Failed';     Label = 'Failed' }
    Error     = @{ Tag = 'ERROR';   Color = 'Red';     Icon = '❌'; Group = 'Failed';     Label = 'Could not read' }
}

function Get-BoardRows {
    <#
    .SYNOPSIS
        Everything worth a line on the results board, one row per app or
        F&O environment, A to Z: results (when applied) or planned actions,
        items held for production, and what could not be read.
        Up-to-date, excluded and unmatched apps are counted, not listed.
    #>
    param($Context)
    $rows = @()
    $new = { param($src, $status, $note)
        [pscustomobject]@{ EnvironmentName = $src.EnvironmentName; EnvironmentId = $src.EnvironmentId; Ring = $src.Ring; Phase = $src.Phase
            AppName = $src.AppName; From = [string]$src.From; To = [string]$src.To; Status = $status; Note = [string]$note } }

    if ($Context.Applied) {
        $map = @{ Succeeded = 'Updated'; AlreadyDone = 'Done'; WouldApply = 'Planned' }
        foreach ($r in $Context.Results) {
            $st = [string]$r.Result
            if ($map.ContainsKey($st)) { $st = $map[$st] }
            $note = $r.Detail
            if ($st -eq 'Planned') { $note = 'whatIf: re-checked, not applied' }
            if ($r.OperationId -and $st -eq 'Started') { $note = "$note (operation $($r.OperationId))" }
            if ($r.PSObject.Properties['Reason'] -and $r.Reason -and $st -in @('Updated', 'Started', 'Planned')) { $note = "$note · proven: $($r.Reason)" }
            $rows += & $new $r $st $note
        }
    }
    else {
        foreach ($a in $Context.Actions) {
            $note = ''
            if ($a.Reason) { $note = "proven: $($a.Reason)" }
            $rows += & $new $a 'Planned' $note
        }
    }
    foreach ($d in $Context.Decisions) {
        if ($d.Code -eq 'HeldForProduction' -and ($Context.Ring -eq 'All' -or $Context.Ring -eq 'Production')) {
            $rows += & $new $d 'Held' ([string]$d.Reason -replace '^held for production: ', '')
        }
        elseif ($d.Outcome -eq 'Error' -and $Context.CountPlanErrors) { $rows += & $new $d 'Error' $d.Reason }
    }
    foreach ($st in @($Context.AppStates)) {
        if (-not $st) { continue }
        $why = ''
        if ($st.PackagesError) { $why = "app packages could not be listed: $($st.PackagesError)" }
        elseif ($st.SolutionsError) { $why = "installed solutions could not be read (apps skipped): $($st.SolutionsError)" }
        if ($why) {
            $rows += [pscustomobject]@{ EnvironmentName = $st.Env.DisplayName; EnvironmentId = $st.Env.Id; Ring = $st.Env.Ring; Phase = 'Apps'
                AppName = '(all apps)'; From = ''; To = ''; Status = 'Error'; Note = $why }
        }
    }
    return @(Sort-ByEnvironment $rows)
}

function Get-StatusCounts {
    param($Rows, $Context)
    $c = [ordered]@{ Updated = 0; InProgress = 0; Planned = 0; Held = 0; Attention = 0; Failed = 0; UpToDate = 0 }
    foreach ($r in $Rows) { $c[$script:StatusStyle[$r.Status].Group]++ }
    $c.UpToDate += Get-Count @($Context.Decisions | Where-Object { $_.Code -eq 'UpToDate' })
    return $c
}

function Format-Version {
    param([string] $From, [string] $To)
    if (-not $From -and -not $To) { return '' }
    if (-not $From) { return "-> $To" }
    return "$From -> $To"
}

function Write-ResultsBoard {
    <#
    .SYNOPSIS
        The last view in the log: every environment A to Z, and under it a
        colour-coded line per app that changed, is changing, is held or
        failed. Fixed-width tags keep it readable without colour.
    #>
    param($Context, $Rows, $Counts)
    $title = 'RESULTS (A–Z)'
    if (-not $Context.Applied) { $title = 'PLAN (A–Z)' }
    Write-Section $title

    $parts = @()
    foreach ($k in $Counts.Keys) {
        if ($Counts[$k] -gt 0) {
            $label = @{ Updated = 'updated'; InProgress = 'in progress'; Planned = 'planned'; Held = 'held for production'; Attention = 'need attention'; Failed = 'failed'; UpToDate = 'up to date' }[$k]
            $parts += "$($Counts[$k]) $label"
        }
    }
    if ((Get-Count $parts) -eq 0) { $parts = @('nothing to do') }
    Write-Line ("{0} environment(s) · {1}" -f (Get-Count $Context.Environments), ($parts -join ' · '))
    Write-Line 'Legend: [UPDATED] [CURRENT] green · [RUNNING] [PLANNED] blue · [HELD] purple · [CHANGED] [STOPPED] [MANUAL] [ADMIN] yellow · [FAILED] [ERROR] red'

    $appWidth = 24
    foreach ($r in $Rows) { if ($r.AppName.Length -gt $appWidth) { $appWidth = [Math]::Min($r.AppName.Length, 40) } }
    $verWidth = 20
    foreach ($r in $Rows) { $v = (Format-Version $r.From $r.To).Length; if ($v -gt $verWidth) { $verWidth = [Math]::Min($v, 48) } }

    foreach ($e in (Sort-ByDisplayName $Context.Environments)) {
        $mine = @($Rows | Where-Object { $_.EnvironmentId -eq $e.Id })
        $upToDate = Get-Count @($Context.Decisions | Where-Object { $_.EnvironmentId -eq $e.Id -and $_.Code -eq 'UpToDate' })
        $bits = @()
        foreach ($grp in @('Updated', 'InProgress', 'Planned', 'Held', 'Attention', 'Failed')) {
            $n = Get-Count @($mine | Where-Object { $script:StatusStyle[$_.Status].Group -eq $grp })
            if ($n -gt 0) { $bits += "$n $(@{ Updated = 'updated'; InProgress = 'in progress'; Planned = 'planned'; Held = 'held'; Attention = 'attention'; Failed = 'failed' }[$grp])" }
        }
        if ($upToDate -gt 0) { $bits += "$upToDate up to date" }
        if ((Get-Count $bits) -eq 0) { $bits = @('nothing to do') }
        Write-Line ''
        Write-Line ("{0}  [{1}]  {2}" -f $e.DisplayName, $e.Ring, ($bits -join ', '))
        foreach ($r in $mine) {
            $style = $script:StatusStyle[$r.Status]
            $app = $r.AppName
            if ($app.Length -gt 40) { $app = $app.Substring(0, 39) + '…' }
            $line = "  [{0,-7}] {1} {2}" -f $style.Tag, $app.PadRight($appWidth), (Format-Version $r.From $r.To).PadRight($verWidth)
            if ($r.Note) { $line += "  $($r.Note)" }
            Write-Colored -Text $line.TrimEnd() -Color $style.Color
        }
    }
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
    $foSkips = Sort-ByEnvironment @($Context.Decisions | Where-Object { $_.Phase -eq 'FinOps' -and $_.Outcome -eq 'Skip' -and $_.Code -ne 'HeldForProduction' })
    $envRows = @(Get-EnvironmentRows -Context $Context)
    $foRows = @()
    if ($Context.FinOpsStates) { $foRows = @(Get-FinOpsInventoryRows -States $Context.FinOpsStates) }

    $board = @(Get-BoardRows -Context $Context)
    $counts = Get-StatusCounts -Rows $board -Context $Context

    # ---------------- console ----------------
    if ((Get-Count $foRows) -gt 0) {
        Start-Group 'Finance and Operations inventory'
        Write-Line (($foRows | Format-Table Environment, Ring, Application, Train, Deployment, AOS, MaintenanceCadence, MaintenanceDays -AutoSize | Out-String -Width 220).TrimEnd())
        Stop-Group
    }
    Write-ResultsBoard -Context $Context -Rows $board -Counts $counts
    Write-Line ''
    $resultColor = @{ Succeeded = 'Green'; SucceededWithIssues = 'Yellow' }[$result]
    Write-Colored -Text ("Result: {0}  ·  mode {1}  ·  ring {2}" -f $result, $Context.Mode, $Context.Ring) -Color $resultColor

    # ---------------- summary.md ----------------
    $resultIcon = @{ Succeeded = '✅'; SucceededWithIssues = '⚠️' }[$result]
    $hostName = @{ AzureDevOps = 'Azure DevOps'; GitHub = 'GitHub Actions'; Local = 'local run' }[(Get-HostKind)]
    $md = @()
    $md += "## $resultIcon d365-tenant-app-updater $($Context.Version) · $result"
    $md += ''
    $md += "**$($Context.Mode)** · ring **$($Context.Ring)** · $hostName · $((Get-Now).ToString('yyyy-MM-dd HH:mm')) UTC · $((Get-Count $Context.Environments)) environment(s)"
    if ($Settings.PlanOnly) { $md += ''; $md += '> **whatIf is on: nothing was changed.**' }
    $md += ''
    $md += '| ✅ Updated | ⏳ In progress | 🗓️ Planned | ⏸️ Held for production | ⚠️ Needs attention | ❌ Failed | ✔️ Up to date |'
    $md += '|:---:|:---:|:---:|:---:|:---:|:---:|:---:|'
    $md += "| **$($counts.Updated)** | **$($counts.InProgress)** | **$($counts.Planned)** | **$($counts.Held)** | **$($counts.Attention)** | **$($counts.Failed)** | **$($counts.UpToDate)** |"
    $md += ''

    if ((Get-Count $board) -gt 0) {
        $heading = '### Results (A–Z)'
        if (-not $Context.Applied) { $heading = '### Planned (A–Z)' }
        $md += $heading
        $md += ConvertTo-MdTable -Headers @('Status', 'Environment', 'Ring', 'App', 'From', 'To', 'Note') -Rows $board -Cells @(
            { "$($script:StatusStyle[$args[0].Status].Icon) $($script:StatusStyle[$args[0].Status].Label)" },
            { $args[0].EnvironmentName }, { $args[0].Ring }, { $args[0].AppName }, { $args[0].From }, { $args[0].To }, { $args[0].Note })
        $md += ''
        if ($counts.Held -gt 0) {
            $md += '_⏸️ Held for production: production takes a version only after a non-production environment runs it (productionRing = true)._'
            $md += ''
        }
    }
    else {
        $md += '_Nothing to update: every app in scope is up to date._'
        $md += ''
    }

    $attention = @($board | Where-Object { $script:StatusStyle[$_.Status].Group -in @('Attention', 'Failed') })
    if ((Get-Count $attention) -gt 0) {
        $md += '### Needs attention'
        foreach ($r in $attention) {
            $what = $r.AppName
            if ($r.To) { $what += " $($r.To)" }
            $md += "- $($script:StatusStyle[$r.Status].Icon) **$($r.EnvironmentName)** · ${what} · **$($script:StatusStyle[$r.Status].Label)**: $($r.Note)"
        }
        $md += ''
    }
    if ((Get-Count $envRows) -gt 0) {
        $md += '### Environments (A–Z)'
        $md += ConvertTo-MdTable -Headers @('', 'Environment', 'Ring', 'Updates', 'Held', 'Up to date', 'Excluded', 'No match', 'F&O') -Rows $envRows -Cells @(
            { if ($args[0].Status -ne 'ok') { '❌' } elseif ($args[0].Updates -gt 0) { '🔄' } elseif ($args[0].Held -gt 0) { '⏸️' } else { '✔️' } },
            { if ($args[0].Status -ne 'ok') { "$($args[0].Environment) – $($args[0].Status)" } else { $args[0].Environment } },
            { $args[0].Ring }, { $args[0].Updates }, { $args[0].Held }, { $args[0].UpToDate }, { $args[0].Excluded }, { $args[0].NoMatch }, { $args[0].FinOps })
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
        board = @($board | Select-Object Status, Ring, EnvironmentId, EnvironmentName, Phase, AppName, From, To, Note)
        counts = $counts
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
