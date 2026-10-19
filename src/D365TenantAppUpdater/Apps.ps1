# Phase 1: Dynamics 365 apps.
#
# Collect: for every environment (A to Z), the available app packages
# (App Management API) and the installed managed-solution versions
# (Dataverse). Plan: per app, decide update / retry / skip, including the
# production ring rule. Only apps already installed in an environment are
# ever touched; nothing new is installed.

$script:FinOpsMarkers = @('msdyn_financeandoperationsprovisioningapp', 'financeandoperationsprovisioning', 'dynamics365financeandoperations')
$script:FinOpsNotMarkers = @('package manager', 'virtual entity', 'virtualentity', 'dual-write', 'dual write', 'dualwrite')
$script:CatalogDumpHints = @('crm', 'hub', 'sales', 'insight', 'productivity', 'globalization', 'quality', 'channel', 'customerservice', 'outlook')

function Get-SolutionMap {
    <#
    .SYNOPSIS
        Managed solutions of one environment: name (lower case) -> { Version; ModifiedOn }.
        Keyed by unique name and, when not already taken, by friendly name.
        Throws on failure (no installed data => nothing is installed blindly).
    #>
    param($Settings, [string] $InstanceUrl, [string[]] $DumpHints = @())
    $base = $InstanceUrl.TrimEnd('/')
    # No $top: it suppresses @odata.nextLink and would silently cap the read.
    $url = "$base/api/data/v9.2/solutions?`$select=uniquename,friendlyname,version,modifiedon&`$filter=ismanaged eq true"
    $map = @{}
    $script:SolutionsRead = 0
    if ((Get-Count $DumpHints) -gt 0) { Start-Group 'DIAGNOSTIC: managed solutions matching hints (uniquename | friendlyname | version)' }
    while ($url) {
        $r = Invoke-Http -Method 'GET' -Uri $url -Headers (Get-DataverseHeaders -Settings $Settings -InstanceUrl $base)
        if (-not (Test-HttpOk $r)) { throw "Dataverse solutions read failed: $(Format-RestFailure $r)" }
        foreach ($s in @($r.Json.value)) {
            if (-not $s.version) { continue }
            $script:SolutionsRead++
            $mod = $null
            if ($s.PSObject.Properties['modifiedon'] -and $s.modifiedon) {
                $d = [datetime]::MinValue
                if ([datetime]::TryParse([string]$s.modifiedon, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { $mod = $d }
            }
            $entry = [pscustomobject]@{ Version = [string]$s.version; ModifiedOn = $mod }
            if ($s.uniquename) { $map[([string]$s.uniquename).ToLowerInvariant()] = $entry }
            if ($s.friendlyname) {
                $fk = ([string]$s.friendlyname).ToLowerInvariant()
                if (-not $map.ContainsKey($fk)) { $map[$fk] = $entry }
            }
            if ((Get-Count $DumpHints) -gt 0) {
                $hay = "$($s.uniquename) $($s.friendlyname)".ToLowerInvariant()
                foreach ($h in $DumpHints) { if ($hay -like "*$h*") { Write-Line ("  [solution] {0} | {1} | {2}" -f $s.uniquename, $s.friendlyname, $s.version); break } }
            }
        }
        $url = $null
        if ($r.Json.PSObject.Properties['@odata.nextLink']) { $url = [string]$r.Json.'@odata.nextLink' }
    }
    if ((Get-Count $DumpHints) -gt 0) { Stop-Group }
    return $map
}

function Resolve-InstalledApp {
    param($Pkg, [hashtable] $Map)
    foreach ($key in @($Pkg.uniqueName, $Pkg.localizedName, $Pkg.applicationName)) {
        if ($key) {
            $k = ([string]$key).ToLowerInvariant()
            if ($Map.ContainsKey($k)) { return $Map[$k] }
        }
    }
    return $null
}

function Get-FinOpsMarkerPackage {
    # Two passes so the result never depends on package order (v2.4.3):
    # unique-name markers across ALL packages first, then a display-name
    # fallback that ignores apps which only mention F&O in their name.
    # Presence only: the Anchor Solution's VERSION is never used.
    param($Packages)
    $installed = @()
    foreach ($p in @($Packages)) {
        $state = [string]$p.state
        if ($state -eq 'Installed' -or $state -eq 'InstallFailed') { $installed += $p }
    }
    foreach ($m in $script:FinOpsMarkers) {
        foreach ($p in $installed) {
            $un = ([string]$p.uniqueName).ToLowerInvariant()
            if (-not $un.Contains($m)) { continue }
            $isOther = $false
            foreach ($x in $script:FinOpsNotMarkers) { if ($un.Contains($x.Replace(' ', '').Replace('-', ''))) { $isOther = $true } }
            if (-not $isOther) { return $p }
        }
    }
    foreach ($p in $installed) {
        $ln = ([string]$p.localizedName).ToLowerInvariant()
        if (-not $ln.Contains('finance and operations')) { continue }
        $isOther = $false
        foreach ($x in $script:FinOpsNotMarkers) { if ($ln.Contains($x)) { $isOther = $true } }
        if (-not $isOther) { return $p }
    }
    return $null
}

function Test-FinOpsProvisioningPackage {
    # True only for the F&O provisioning app itself (unique-name marker).
    param($Pkg)
    $un = ([string]$Pkg.uniqueName).ToLowerInvariant()
    foreach ($m in $script:FinOpsMarkers) { if ($un.Contains($m)) { return $true } }
    return $false
}

function Test-AppExcluded {
    <#
    .SYNOPSIS
        Matches appExclude entries against an app's unique name, display name,
        application name and id. Exact or wildcard (*) matches are the
        supported forms. A plain value that only matches as a SUBSTRING still
        excludes the app (v2 behaviour kept), but is reported as deprecated.
        Returns { Excluded; By; Substring }.
    #>
    param($Pkg, $List)
    $none = [pscustomobject]@{ Excluded = $false; By = ''; Substring = $false }
    if ((Get-Count $List) -eq 0) { return $none }
    $keys = @()
    foreach ($k in @($Pkg.uniqueName, $Pkg.localizedName, $Pkg.applicationName, $Pkg.applicationId)) { if ($k) { $keys += ([string]$k).ToLowerInvariant() } }
    $substringHit = $null
    foreach ($item in $List) {
        $needle = ([string]$item).Trim().ToLowerInvariant()
        if ($needle -eq '') { continue }
        foreach ($k in $keys) {
            if ($k -eq $needle) { return [pscustomobject]@{ Excluded = $true; By = [string]$item; Substring = $false } }
            if ($needle.Contains('*')) { if ($k -like $needle) { return [pscustomobject]@{ Excluded = $true; By = [string]$item; Substring = $false } } }
            elseif (-not $substringHit -and $k.Contains($needle)) { $substringHit = [string]$item }
        }
    }
    if ($substringHit) { return [pscustomobject]@{ Excluded = $true; By = $substringHit; Substring = $true } }
    return $none
}

function Get-AppDisplayName {
    param($Pkg)
    if ($Pkg.localizedName) { return [string]$Pkg.localizedName }
    return [string]$Pkg.uniqueName
}

function Get-AppEnvironmentState {
    <#
    .SYNOPSIS
        Collects one environment's app data. Never throws; errors are recorded.
    #>
    param($Settings, $EnvObj, [bool] $DumpCatalog = $false)
    $state = [pscustomobject]@{
        Env = $EnvObj; Packages = @(); FinOpsMarker = $null; Solutions = $null; SolutionCount = 0
        PackagesError = ''; SolutionsError = ''
    }
    try {
        $uri = New-PpUrl -Settings $Settings -Path "/appmanagement/environments/$($EnvObj.Id)/applicationPackages" -Query @{ appInstallState = 'All'; lcid = '1033' }
        $r = Invoke-Http -Method 'GET' -Uri $uri -Headers (Get-PpHeaders $Settings)
        if (-not (Test-HttpOk $r)) { $state.PackagesError = "$(Format-RestFailure $r). $(Get-ApiErrorMessage $r)" }
        else { $state.Packages = @($r.Json.value) }
    }
    catch { $state.PackagesError = Get-ErrorText $_ }
    if ($state.PackagesError) { return $state }

    $state.FinOpsMarker = Get-FinOpsMarkerPackage -Packages $state.Packages
    try {
        $hints = @()
        if ($DumpCatalog) { $hints = $script:CatalogDumpHints }
        $state.Solutions = Get-SolutionMap -Settings $Settings -InstanceUrl $EnvObj.InstanceUrl -DumpHints $hints
        $state.SolutionCount = $script:SolutionsRead
    }
    catch { $state.SolutionsError = Get-ErrorText $_ }
    return $state
}

function New-AppDecision {
    param($State, $Pkg, [string] $Kind, [string] $Outcome, [string] $Code, [string] $Reason, [string] $From = '', [string] $To = '')
    return [pscustomobject]@{
        Phase = 'Apps'; Kind = $Kind; Outcome = $Outcome; Code = $Code; Reason = $Reason
        EnvironmentId = $State.Env.Id; EnvironmentName = $State.Env.DisplayName; Ring = $State.Env.Ring
        AppUniqueName = [string]$Pkg.uniqueName; AppName = (Get-AppDisplayName $Pkg)
        From = $From; To = $To; Package = $Pkg
    }
}

function Get-AppProofIndex {
    # uniqueName (lower) -> @({ Version; ModifiedOn; Environment }) for every
    # NON-production environment where the app is installed. Read live; no
    # state store needed.
    param($States)
    $index = @{}
    foreach ($s in $States) {
        if ($s.Env.Ring -ne 'NonProduction' -or $s.PackagesError -or $s.SolutionsError -or $null -eq $s.Solutions) { continue }
        foreach ($p in $s.Packages) {
            if ([string]$p.state -ne 'Installed' -or -not $p.uniqueName) { continue }
            $inst = Resolve-InstalledApp -Pkg $p -Map $s.Solutions
            if (-not $inst) { continue }
            $k = ([string]$p.uniqueName).ToLowerInvariant()
            if (-not $index.ContainsKey($k)) { $index[$k] = @() }
            $index[$k] += [pscustomobject]@{ Version = $inst.Version; ModifiedOn = $inst.ModifiedOn; Environment = $s.Env.DisplayName }
        }
    }
    return $index
}

function Test-AppProven {
    <#
    .SYNOPSIS
        Production ring rule for apps: a production environment may take
        version $Target only if at least one non-production environment
        already runs $Target or newer (and, with productionSoakDays > 0, has
        not changed that solution for that many days).
        Returns { Proven; By; Reason }.
    #>
    param([hashtable] $Index, [string] $UniqueName, [string] $Target, [int] $SoakDays)
    $k = $UniqueName.ToLowerInvariant()
    if (-not $Index.ContainsKey($k)) { return [pscustomobject]@{ Proven = $false; By = ''; Reason = 'not installed in any non-production environment in scope' } }
    $cutoff = (Get-Now).AddDays(-$SoakDays)
    $closest = $null
    foreach ($p in (Sort-Items $Index[$k] @({ $_.Environment }))) {
        if (-not (Test-VersionAtLeast -Version $p.Version -Minimum $Target)) { continue }
        if ($SoakDays -le 0) { return [pscustomobject]@{ Proven = $true; By = $p.Environment; Reason = '' } }
        if ($p.ModifiedOn -and $p.ModifiedOn -le $cutoff) { return [pscustomobject]@{ Proven = $true; By = $p.Environment; Reason = '' } }
        if (-not $closest) { $closest = $p }
    }
    if ($closest) { return [pscustomobject]@{ Proven = $false; By = ''; Reason = "running in $($closest.Environment), but for less than $SoakDays day(s)" } }
    $best = Select-HighestVersion -Versions ($Index[$k] | ForEach-Object { $_.Version })
    return [pscustomobject]@{ Proven = $false; By = ''; Reason = "non-production runs at most $best" }
}

function New-AppPlan {
    <#
    .SYNOPSIS
        Decides, per environment (A to Z) and per app (A to Z), what to do.
        Returns the decisions (actions and skips) plus the deprecation
        warnings to report.
    #>
    param($Settings, $States)
    $decisions = @()
    $warnings = @()
    $proof = Get-AppProofIndex -States $States
    $substringWarned = @{}

    foreach ($s in $States) {
        if ($s.PackagesError -or $s.SolutionsError) { continue }
        $candidates = @()
        foreach ($p in $s.Packages) {
            if (-not $p.uniqueName) { continue }
            $st = [string]$p.state
            if ($st -ne 'Installed' -and -not ($Settings.RetryFailedInstalls -and $st -eq 'InstallFailed')) { continue }
            # Only the real F&O provisioning app is left alone (Microsoft
            # updates it with F&O). A package found by the display-name
            # fallback, such as Copilot for finance and operations apps, only
            # signals that F&O is there: it is still an app to keep current.
            if ($s.FinOpsMarker -and $p.uniqueName -eq $s.FinOpsMarker.uniqueName -and (Test-FinOpsProvisioningPackage $p)) { continue }
            $candidates += $p
        }
        $candidates = @(Sort-Items $candidates @({ Get-AppDisplayName $_ }, { [string]$_.uniqueName }))

        foreach ($pkg in $candidates) {
            $avail = [string]$pkg.version
            $ex = Test-AppExcluded -Pkg $pkg -List $Settings.AppExclude
            if ($ex.Excluded) {
                $decisions += New-AppDecision -State $s -Pkg $pkg -Kind 'App' -Outcome 'Skip' -Code 'Excluded' -Reason "appExclude '$($ex.By)'"
                if ($ex.Substring -and -not $substringWarned.ContainsKey($ex.By)) {
                    $substringWarned[$ex.By] = $true
                    $warnings += "appExclude '$($ex.By)' matched '$((Get-AppDisplayName $pkg))' only as part of its name. Partial matching is deprecated and will be removed in a future major version: use the exact unique name, or a wildcard such as '*$($ex.By)*'."
                }
                continue
            }

            $isRetry = ([string]$pkg.state -eq 'InstallFailed')
            $inst = $null
            if (-not $isRetry) {
                $inst = Resolve-InstalledApp -Pkg $pkg -Map $s.Solutions
                if (-not $inst) { $decisions += New-AppDecision -State $s -Pkg $pkg -Kind 'App' -Outcome 'Skip' -Code 'NoSolutionMatch' -Reason 'no matching managed solution, so the installed version is unknown' -To $avail; continue }
                if (-not (Test-UpdateAvailable -Available $avail -Installed $inst.Version)) { $decisions += New-AppDecision -State $s -Pkg $pkg -Kind 'App' -Outcome 'Skip' -Code 'UpToDate' -Reason 'up to date' -From $inst.Version -To $avail; continue }
            }

            $kind = 'AppUpdate'
            $from = ''
            if ($isRetry) { $kind = 'AppRetry'; $from = '(failed install)' } else { $from = $inst.Version }

            if ($Settings.ProductionRing -and $s.Env.Ring -eq 'Production') {
                $pr = Test-AppProven -Index $proof -UniqueName ([string]$pkg.uniqueName) -Target $avail -SoakDays $Settings.ProductionSoakDays
                if (-not $pr.Proven) {
                    $decisions += New-AppDecision -State $s -Pkg $pkg -Kind $kind -Outcome 'Skip' -Code 'HeldForProduction' -Reason "held for production: $($pr.Reason)" -From $from -To $avail
                    continue
                }
                $decisions += New-AppDecision -State $s -Pkg $pkg -Kind $kind -Outcome 'Action' -Code 'Proven' -Reason "already runs in $($pr.By)" -From $from -To $avail
                continue
            }
            $decisions += New-AppDecision -State $s -Pkg $pkg -Kind $kind -Outcome 'Action' -Code '' -Reason '' -From $from -To $avail
        }
    }
    return [pscustomobject]@{ Decisions = $decisions; Warnings = $warnings }
}
