# Small, dependency-free helpers used everywhere.

function Get-Count {
    param($Value)
    $n = 0
    if ($null -ne $Value) { foreach ($x in $Value) { $n++ } }
    return $n
}

function ConvertTo-SafeBool {
    # For switches where a typo must not silently pick the unsafe value:
    # recognised true/false words win; anything else keeps the safe
    # default and returns a warning. Returns { Value; Warning }.
    param([AllowEmptyString()] [string] $Text, [bool] $SafeDefault, [string] $Name)
    if ([string]::IsNullOrWhiteSpace($Text)) { return [pscustomobject]@{ Value = $SafeDefault; Warning = '' } }
    $t = $Text.Trim().ToLowerInvariant()
    if (@('true', '1', 'yes', 'y', 'on') -contains $t) { return [pscustomobject]@{ Value = $true; Warning = '' } }
    if (@('false', '0', 'no', 'n', 'off') -contains $t) { return [pscustomobject]@{ Value = $false; Warning = '' } }
    return [pscustomobject]@{ Value = $SafeDefault; Warning = "$Name value '$Text' is not true or false. Using the safe value $($SafeDefault.ToString().ToLowerInvariant())." }
}

function ConvertTo-Bool {
    param([AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return @('true', '1', 'yes', 'y', 'on') -contains ($Text.Trim().ToLowerInvariant())
}

function Split-List {
    param([AllowEmptyString()] [string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    $out = @()
    foreach ($piece in $Text.Split(',')) {
        $t = $piece.Trim()
        if ($t -ne '') { $out += $t }
    }
    return $out
}

function Join-Names {
    param($Items)
    $parts = @()
    foreach ($i in $Items) { if ($null -ne $i) { $parts += [string]$i } }
    if ($parts.Count -eq 0) { return '' }
    return [string]::Join(', ', $parts)
}

function Format-Scope {
    param([AllowEmptyString()] [string] $Raw, [string] $EmptyLabel)
    $list = Split-List $Raw
    if ((Get-Count $list) -eq 0) { return $EmptyLabel }
    return (Join-Names $list)
}

function Get-ErrorText {
    # PowerShell puts an HTTP error body in ErrorDetails.Message, not
    # Exception.Message. Read both (CONTRIBUTING, trap 3).
    param($ErrorRecord)
    $parts = @()
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $parts += [string]$ErrorRecord.ErrorDetails.Message }
    if ($ErrorRecord.Exception -and $ErrorRecord.Exception.Message)       { $parts += [string]$ErrorRecord.Exception.Message }
    if ($parts.Count -eq 0) { return [string]$ErrorRecord }
    return [string]::Join(' ', $parts)
}

function Get-SortKey {
    # Natural, culture-independent sort key, so every agent (Windows or
    # Linux, any locale) produces exactly the same A to Z order:
    #   - case-insensitive                     (contoso = Contoso)
    #   - numbers in numeric order             (Dev2 before Dev10)
    #   - '-', '_', '.' and spaces count alike (Dev-UAT next to Dev_UAT)
    # Keys are compared ordinally (Sort-Items), never with culture rules.
    param([AllowEmptyString()] [AllowNull()] [string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text.ToLowerInvariant() -replace '[\s\-_.]+', ' '
    $t = $t.Trim()
    return [regex]::Replace($t, '\d+', { param($m) $m.Value.TrimStart('0').PadLeft(12, '0') })
}

function Sort-Items {
    <#
    .SYNOPSIS
        Stable sort by one or more keys, compared ordinally. Each key is a
        scriptblock using $_; strings go through Get-SortKey, numbers are
        compared as numbers. Use this instead of Sort-Object for anything a
        person reads, because Sort-Object compares strings with culture rules.
    #>
    param($Items, [scriptblock[]] $By)
    $arr = @($Items)
    if ($arr.Count -le 1) { return $arr }
    $sep = [string][char]1
    $keys = [string[]]::new($arr.Count)
    for ($i = 0; $i -lt $arr.Count; $i++) {
        $parts = foreach ($b in $By) {
            $v = $b.InvokeWithContext($null, [System.Collections.Generic.List[psvariable]]@([psvariable]::new('_', $arr[$i])))
            $v = if ($v.Count -gt 0) { $v[0] } else { $null }
            if ($v -is [int] -or $v -is [long]) { ([long]$v + 1000000000).ToString('D12') }
            else { Get-SortKey ([string]$v) }
        }
        $keys[$i] = (@($parts) + @($i.ToString('D9'))) -join $sep
    }
    # Explicit ordinal comparison. ([Array]::Sort(keys, items, comparer)
    # binds to an overload that sorts a converted copy in PowerShell.)
    $pairs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $arr.Count; $i++) { $pairs.Add([pscustomobject]@{ K = $keys[$i]; V = $arr[$i] }) }
    $pairs.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.K, $b.K) })
    return @($pairs | ForEach-Object { $_.V })
}

function Sort-ByDisplayName {
    # Environments are always processed and listed A to Z by display name
    # (ties broken by id, so the order is stable).
    param($Items)
    return @(Sort-Items $Items @({ $_.DisplayName }, { [string]$_.Id }))
}

function Get-Now {
    # Wrapped so tests can freeze the clock.
    return [datetime]::UtcNow
}
