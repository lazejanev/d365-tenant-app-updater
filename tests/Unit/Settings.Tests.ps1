BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
}

Describe 'Settings' {
    BeforeEach { Reset-TestModuleState }

    It 'uses the built-in defaults' {
        InModuleScope D365TenantAppUpdater {
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't' }
            $s.ProductionRing | Should -BeTrue
            $s.ProductionEnvironmentTypes | Should -Be @('Production')
            $s.FinOpsApplyVersion | Should -BeFalse
            $s.FinOpsUpdateScope | Should -Be 'QualityUpdate'
            $s.WaitForInstallsMinutes | Should -Be 0
            $s.AuthMode | Should -Be 'Auto'
            $s.Authority | Should -Be 'https://login.microsoftonline.com/t/oauth2/v2.0/token'
            $s.Warnings | Should -HaveCount 0
        }
    }

    It 'prefers parameter, then queue-time override, then variable, then default' {
        InModuleScope D365TenantAppUpdater {
            $env:FinOpsUpdateScope = 'VersionUpdate'
            (Get-RunSettings).FinOpsUpdateScope | Should -Be 'VersionUpdate'
            $env:FinOpsUpdateScopeOverride = 'Any'
            (Get-RunSettings).FinOpsUpdateScope | Should -Be 'Any'
            (Get-RunSettings -Bound @{ FinOpsUpdateScope = 'qualityupdate' }).FinOpsUpdateScope | Should -Be 'QualityUpdate'
        }
    }

    It 'treats unexpanded pipeline macros and placeholders as unset' -ForEach @(
        @{ V = '$(environmentFilter)' }, @{ V = '${{ parameters.x }}' }, @{ V = '(all)' }, @{ V = '   ' }
    ) {
        InModuleScope D365TenantAppUpdater -Parameters @{ V = $V } {
            param($V)
            $env:EnvironmentFilter = $V
            (Get-RunSettings).EnvironmentFilter | Should -HaveCount 0
        }
    }

    It 'keeps the v2 UsePacFallbackOverride name working' {
        InModuleScope D365TenantAppUpdater {
            $env:UsePacFallbackOverride = 'true'
            (Get-RunSettings).UsePacFallback | Should -BeTrue
        }
    }

    It 'warns on invalid values and falls back' {
        InModuleScope D365TenantAppUpdater {
            $s = Get-RunSettings -Bound @{ FinOpsUpdateScope = 'Everything'; AuthMode = 'Magic'; ProductionSoakDays = 'two'; WaitForInstallsMinutes = '-1' }
            $s.FinOpsUpdateScope | Should -Be 'QualityUpdate'
            $s.AuthMode | Should -Be 'Auto'
            $s.ProductionSoakDays | Should -Be 0
            $s.WaitForInstallsMinutes | Should -Be 0
            $s.Warnings | Should -HaveCount 4
        }
    }

    It 'keeps the safe value for mistyped safety switches' {
        InModuleScope D365TenantAppUpdater {
            $s = Get-RunSettings -Bound @{ ProductionRing = 'ture'; WhatIf = 'nope'; FinOpsApplyVersion = 'yes please' }
            $s.ProductionRing | Should -BeTrue
            $s.PlanOnly | Should -BeTrue
            $s.FinOpsApplyVersion | Should -BeFalse
            $s.Warnings | Should -HaveCount 3
            (Get-RunSettings -Bound @{ ProductionRing = 'OFF' }).ProductionRing | Should -BeFalse
        }
    }

    It 'splits lists on commas and trims entries' {
        InModuleScope D365TenantAppUpdater {
            (Get-RunSettings -Bound @{ EnvironmentExclude = ' A, B ,C,' }).EnvironmentExclude | Should -Be @('A', 'B', 'C')
        }
    }
}
