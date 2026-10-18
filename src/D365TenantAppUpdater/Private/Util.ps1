# Small, dependency-free helpers used everywhere.

function Get-Count {
    param($Value)
    $n = 0
    if ($null -ne $Value) { foreach ($x in $Value) { $n++ } }
    return $n
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
    # Case-insensitive, culture-independent key so the order is the same on
    # every agent, whatever its locale.
    param([AllowEmptyString()] [string] $Text)
    if ($null -eq $Text) { return '' }
    return $Text.ToLowerInvariant()
}

function Sort-ByDisplayName {
    # v3.0.0: environments are always processed and listed A to Z by display
    # name (ties broken by id, so the order is stable).
    param($Items)
    return @($Items | Sort-Object -Property @{ Expression = { Get-SortKey ([string]$_.DisplayName) } }, @{ Expression = { [string]$_.Id } })
}

function Get-Now {
    # Wrapped so tests can freeze the clock.
    return [datetime]::UtcNow
}
