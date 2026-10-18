BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
}

Describe 'Version helpers' {
    It 'Test-UpdateAvailable is strictly newer, never a downgrade' -ForEach @(
        @{ A = '2.0.0.0'; I = '1.9.9.9'; E = $true }
        @{ A = '1.0.0.0'; I = '1.0.0.0'; E = $false }
        @{ A = '1.0.0.0'; I = '1.0.0.1'; E = $false }
        @{ A = '1.0.10'; I = '1.0.9'; E = $true }
        @{ A = '9.2.24101.191'; I = '9.2.24101.19'; E = $true }
    ) {
        InModuleScope D365TenantAppUpdater -Parameters @{ A = $A; I = $I; E = $E } {
            param($A, $I, $E)
            Test-UpdateAvailable -Available $A -Installed $I | Should -Be $E
        }
    }

    It 'parses a bare JSON array of versions (member enumeration trap)' {
        InModuleScope D365TenantAppUpdater {
            $j = '[{"version":"10.0.48.9","releaseStage":"QualityUpdate"},{"version":"10.0.49.3","releaseStage":"QualityUpdate"}]' | ConvertFrom-Json
            $l = @(ConvertTo-FinOpsVersionList -Json $j)
            $l | Should -HaveCount 2
            $l[0].Version | Should -Be '10.0.48.9'
        }
    }

    It 'maps the live build to its train via the schedule' {
        InModuleScope D365TenantAppUpdater {
            $p = ConvertFrom-FinOpsSchedule -Text (Get-Content -Raw (Join-Path $global:FixtureDir 'pqu-schedule-50.md'))
            $p.Map['10.0.2911'] | Should -Be 50
            (Get-FinOpsLiveTrain -AppVersion '10.0.2911.70' -Map $p.Map).Train | Should -Be 50
        }
    }

    It 'drops builds the schedule lists under two trains' {
        InModuleScope D365TenantAppUpdater {
            $p = ConvertFrom-FinOpsSchedule -Text (Get-Content -Raw (Join-Path $global:FixtureDir 'pqu-schedule-ambiguous.md'))
            $p.Ambiguous | Should -Contain '10.0.2790'
            $m = ConvertTo-FinOpsBuildTrainMap -BuiltIn $script:FinOpsBuildTrainBuiltIn -Extra '' -Schedule $p.Map -Ambiguous $p.Ambiguous
            $m.Map.ContainsKey('10.0.2790') | Should -BeFalse
        }
    }
}
