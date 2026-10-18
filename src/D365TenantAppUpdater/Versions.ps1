# Version comparison, the F&O version list parser, and the build -> release
# map. Logic unchanged from v2.4.4, which was verified against Microsoft's
# live PQU schedule.

# Fallback only: every run downloads Microsoft's PQU schedule and builds the
# map from it (v2.4.4). Source: "Release schedule for proactive quality
# updates", column "Application Version".
$script:FinOpsBuildTrainBuiltIn = [ordered]@{
    '10.0.2428' = 46
    '10.0.2527' = 47
    '10.0.2645' = 48
    '10.0.2790' = 49
}

# Stages VersionUpdate may select. Anything else (preview, early access, a
# stage this script has never seen) is excluded.
$script:FinOpsReleasedStages = @('GeneralAvailability', 'QualityUpdate')

function Test-UpdateAvailable {
    # True only when Available is strictly newer than Installed. Never a downgrade.
    param([string] $Available, [string] $Installed)
    $a = $null; $i = $null
    if ([System.Version]::TryParse($Available, [ref]$a) -and [System.Version]::TryParse($Installed, [ref]$i)) { return ($a -gt $i) }
    $as = $Available -split '\.'; $is = $Installed -split '\.'
    $n = [Math]::Max($as.Count, $is.Count)
    for ($k = 0; $k -lt $n; $k++) {
        $av = 0; $iv = 0
        [void][int]::TryParse(("$($as[$k])"), [ref]$av)
        [void][int]::TryParse(("$($is[$k])"), [ref]$iv)
        if ($av -ne $iv) { return ($av -gt $iv) }
    }
    return $false
}

function Test-VersionAtLeast {
    param([string] $Version, [string] $Minimum)
    return -not (Test-UpdateAvailable -Available $Minimum -Installed $Version)
}

function Select-HighestVersion {
    param($Versions)
    $best = $null
    foreach ($v in $Versions) {
        $s = [string]$v
        if ($s -eq '') { continue }
        if ($null -eq $best) { $best = $s; continue }
        if (Test-UpdateAvailable -Available $s -Installed $best) { $best = $s }
    }
    return $best
}

function ConvertTo-FinOpsVersionList {
    # Returns @({ Version; ReleaseStage }). Only an OBJECT is unwrapped: on a
    # bare array, member enumeration would turn $Json.value into an array of
    # $nulls (CONTRIBUTING, member enumeration trap; v2.4.3 fix).
    param($Json)
    if ($null -eq $Json) { return @() }
    $items = $Json
    if ($Json -isnot [array]) {
        foreach ($p in @('availableVersions', 'value', 'versions', 'items', 'data')) {
            if ($Json.PSObject.Properties[$p] -and $Json.$p) { $items = $Json.$p; break }
        }
    }
    $out = @()
    $seen = @{}
    foreach ($i in @($items)) {
        $v = $null; $stage = 'Unknown'
        if ($i -is [string]) { $v = $i }
        else {
            foreach ($p in @('version', 'applicationVersion', 'name', 'value')) {
                if ($i.PSObject.Properties[$p] -and $i.$p -and ([string]$i.$p) -match '^\d+(\.\d+)+') { $v = [string]$i.$p; break }
            }
            if ($i.PSObject.Properties['releaseStage'] -and $i.releaseStage) { $stage = [string]$i.releaseStage }
        }
        if ($v -and -not $seen.ContainsKey($v)) {
            $seen[$v] = $true
            $out += [pscustomobject]@{ Version = $v; ReleaseStage = $stage }
        }
    }
    return $out
}

function Get-FinOpsTrain {
    # Release train = 3rd segment of a provisioning version (48 in 10.0.48.7).
    # Used only on versions finopsversions offers, never on the Anchor Solution.
    param([AllowEmptyString()] [string] $Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $null }
    if ($Version -match '^10\.0\.(\d+)\.\d+') { return [int]$Matches[1] }
    return $null
}

function Get-FinOpsScopeLabel {
    param([string] $Scope)
    switch ($Scope) {
        'QualityUpdate' { return 'PQU' }
        'VersionUpdate' { return 'version update' }
        default         { return $Scope }
    }
}

function ConvertFrom-FinOpsSchedule {
    # Parses Microsoft's PQU release schedule (markdown). Uses only rows like
    #   | 10.0.49 PQU-1 | ... | 10.0.2790.83 | 7.0.8199.55 |
    # A prefix seen under two different trains is ambiguous and dropped.
    param([AllowEmptyString()] [string] $Text)
    $seen = @{}; $rows = 0
    foreach ($line in ($Text -split "`n")) {
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ((Get-Count $cells) -lt 2) { continue }
        if ($cells[0] -notmatch '^10\.0\.(\d+)\s+PQU-\d+') { continue }
        $train = [int]$Matches[1]
        foreach ($c in $cells) {
            if ($c -match '^(10\.0\.\d{3,})\.\d+$') {
                $rows++
                $pfx = $Matches[1]
                if (-not $seen.ContainsKey($pfx)) { $seen[$pfx] = @{} }
                $seen[$pfx][$train] = $true
                break
            }
        }
    }
    $map = @{}; $ambiguous = @()
    foreach ($pfx in $seen.Keys) {
        $trains = @($seen[$pfx].Keys)
        if ((Get-Count $trains) -eq 1) { $map[$pfx] = [int]$trains[0] } else { $ambiguous += $pfx }
    }
    return @{ Map = $map; Rows = $rows; Ambiguous = $ambiguous }
}

function Get-FinOpsScheduleMap {
    # Downloads and parses the schedule. Never throws.
    param([AllowEmptyString()] [string] $Url)
    $empty = @{ Map = @{}; Rows = 0; Ambiguous = @(); Error = '' }
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -ieq 'none' -or $Url -ieq 'off') { $empty.Error = 'disabled (finOpsScheduleUrl = none)'; return $empty }
    $r = Invoke-Http -Method 'GET' -Uri $Url -Headers @{ Accept = 'text/plain' }
    if (-not (Test-HttpOk $r)) { $empty.Error = 'download failed: ' + (Format-RestFailure $r); return $empty }
    $parsed = ConvertFrom-FinOpsSchedule -Text ([string]$r.Text)
    if ($parsed.Rows -eq 0) { $empty.Error = 'downloaded, but no "10.0.x PQU-n" rows with an application version were found (page format changed?)'; return $empty }
    return @{ Map = $parsed.Map; Rows = $parsed.Rows; Ambiguous = $parsed.Ambiguous; Error = '' }
}

function ConvertTo-FinOpsBuildTrainMap {
    # Built-in fallback, then Microsoft's schedule, then the optional
    # finOpsBuildTrainMap override. A build the schedule contradicts itself
    # about is removed entirely (ambiguous = unknown = skipped).
    param($BuiltIn, [AllowEmptyString()] [string] $Extra, $Schedule = @{}, $Ambiguous = @())
    $map = @{}
    foreach ($k in $BuiltIn.Keys) { $map[[string]$k] = [int]$BuiltIn[$k] }
    foreach ($k in $Schedule.Keys) { $map[[string]$k] = [int]$Schedule[$k] }
    foreach ($k in $Ambiguous) { if ($map.ContainsKey([string]$k)) { $map.Remove([string]$k) } }
    $invalid = @()
    foreach ($entry in (Split-List $Extra)) {
        if ($entry -match '^\s*(\d+\.\d+\.\d+)\s*=\s*(?:10\.0\.)?(\d+)\s*$') { $map[$Matches[1]] = [int]$Matches[2] }
        else { $invalid += $entry }
    }
    return @{ Map = $map; Invalid = $invalid }
}

function Get-FinOpsLiveTrain {
    # 10.0.2645.136 -> prefix 10.0.2645 -> 48.
    param([AllowEmptyString()] [string] $AppVersion, [hashtable] $Map)
    if ($AppVersion -notmatch '^\s*(\d+\.\d+\.\d+)\.\d+') { return @{ Train = $null; Prefix = '' } }
    $prefix = $Matches[1]
    if ($Map.ContainsKey($prefix)) { return @{ Train = [int]$Map[$prefix]; Prefix = $prefix } }
    return @{ Train = $null; Prefix = $prefix }
}
