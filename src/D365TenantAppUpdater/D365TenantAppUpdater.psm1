#Requires -Version 7.2
Set-StrictMode -Off

# Load every private file in a fixed order: later files use earlier ones.
$script:ModuleRoot = $PSScriptRoot
foreach ($part in @('Util', 'Host', 'Settings', 'Http', 'Auth', 'Versions', 'Discovery', 'Apps', 'FinOps', 'Plan', 'Apply', 'Report', 'Main')) {
    . (Join-Path $PSScriptRoot "Private/$part.ps1")
}

function Get-D365TenantAppUpdaterVersion {
    <#
    .SYNOPSIS
        Returns the module version (the single source of the release number).
    #>
    [CmdletBinding()]
    param()
    return [string](Import-PowerShellDataFile (Join-Path $script:ModuleRoot 'D365TenantAppUpdater.psd1')).ModuleVersion
}

Export-ModuleMember -Function Invoke-D365TenantAppUpdate, Get-D365TenantAppUpdaterVersion
