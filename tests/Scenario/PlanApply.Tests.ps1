# Plan mode, Apply mode (from plan.json) and whatIf.

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
    function Get-InstallCalls { @(Get-FakeCalls 'POST */applicationPackages/*/install*') }
    function Get-ApplyCalls { @(Get-FakeCalls 'POST */finopsversions/*/apply*') }
    function New-TwoRingTenant {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '2.0.0.0'), (New-FakeApp 'msdyn_Hub' 'Customer Service Hub' '5.1.0.0' '5.0.0.0')))
        )
    }
}

Describe 'Plan mode' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'writes plan.json and the reports without changing anything' {
        New-TwoRingTenant
        $r = Invoke-TestRun -Mode Plan
        Get-InstallCalls | Should -HaveCount 0
        Get-ApplyCalls | Should -HaveCount 0
        $r.ExitCode | Should -Be 0
        $r.Plan.schema | Should -Be 'd365-tenant-app-updater/plan@1'
        $r.Plan.tenantId | Should -Be 'tid'
        @($r.Plan.actions) | Should -HaveCount 2
        @($r.Plan.actions | Where-Object Ring -eq 'Production') | Should -HaveCount 1
        $r.Summary | Should -Match '### Planned'
    }

    It 'whatIf = true turns the default PlanAndApply into Plan' {
        New-TwoRingTenant
        $r = Invoke-TestRun -Setting @{ WhatIf = 'true' }
        Get-InstallCalls | Should -HaveCount 0
        $r.Report.mode | Should -Be 'Plan'
        $r.Summary | Should -Match 'nothing was changed'
    }

    It 'publishes has-actions outputs for the next stage or job (GitHub)' {
        Reset-TestModuleState -HostKind GitHub
        $out = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.txt')
        $sum = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N') + '.md')
        $env:GITHUB_OUTPUT = $out; $env:GITHUB_STEP_SUMMARY = $sum
        try {
            Set-FakeTenant -Environments @((New-FakeEnv -Id 'uat' -Name 'UAT' -Apps @((New-FakeApp 'msdyn_Hub' 'Hub' '5.1.0.0' '5.0.0.0'))))
            $null = Invoke-TestRun -Mode Plan
            $lines = Get-Content $out
            $lines | Should -Contain 'hasNonProductionActions=true'
            $lines | Should -Contain 'hasProductionActions=false'
            (Get-Content $sum -Raw) | Should -Match 'd365-tenant-app-updater 3\.0\.0'
        }
        finally { $env:GITHUB_OUTPUT = $null; $env:GITHUB_STEP_SUMMARY = $null }
    }

    It 'publishes has-actions outputs as Azure DevOps output variables' {
        Reset-TestModuleState -HostKind AzureDevOps
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'p' -Name 'P' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Hub' 'Hub' '5.1.0.0' '5.0.0.0'))))
        $r = Invoke-TestRun -Mode Plan -Setting @{ ProductionRing = 'false' }
        $r.Output | Should -Match ([regex]::Escape('##vso[task.setvariable variable=hasProductionActions;isOutput=true]true'))
        $r.Output | Should -Match ([regex]::Escape('##vso[task.setvariable variable=hasNonProductionActions;isOutput=true]false'))
    }
}

Describe 'Apply mode' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('d365tau-' + [guid]::NewGuid().ToString('N'))
        $script:PlanPath = Join-Path $script:Dir 'plan.json'
    }

    It 'applies only the ring it is given' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -Ring NonProduction -PlanFile $script:PlanPath
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/uat/applicationPackages/msdyn_Hub/install*'
        $r.Report.ring | Should -Be 'NonProduction'

        $global:FakeTenant.Calls.Clear()
        $null = Invoke-TestRun -Mode Apply -Ring Production -PlanFile $script:PlanPath
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/prod/applicationPackages/msdyn_Sales/install*'
    }

    It 'does not install an app that is already at the planned version' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir
        $global:FakeTenant.Environments[1].Apps[1].Installed = '5.1.0.0'
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -Ring NonProduction -PlanFile $script:PlanPath
        Get-InstallCalls | Should -HaveCount 0
        $r.Report.results[0].Result | Should -Be 'AlreadyDone'
        $r.ExitCode | Should -Be 0
    }

    It 'does not install a version that changed since the plan (it was never proven)' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir
        $global:FakeTenant.Environments[0].Apps[0].Available = '2.1.0.0'
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -Ring Production -PlanFile $script:PlanPath
        Get-InstallCalls | Should -HaveCount 0
        $r.Report.results[0].Result | Should -Be 'Stale'
        $r.Summary | Should -Match 'Changed since plan'
    }

    It 'does not apply an F&O version that is no longer offered' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -FinOpsBuild '10.0.2645.136' -FinOpsVersions '[{"version":"10.0.48.9","releaseStage":"QualityUpdate"}]'))
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir -Setting @{ FinOpsApplyVersion = 'true' }
        $global:FakeTenant.Environments[0].FinOpsVersions = '[{"version":"10.0.48.11","releaseStage":"QualityUpdate"}]'
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -PlanFile $script:PlanPath -Setting @{ FinOpsApplyVersion = 'true' }
        Get-ApplyCalls | Should -HaveCount 0
        $r.Report.results[0].Result | Should -Be 'Stale'
    }

    It 'applies the F&O version from the plan when it is still offered' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -FinOpsBuild '10.0.2645.136' -FinOpsVersions '[{"version":"10.0.48.9","releaseStage":"QualityUpdate"}]'))
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir -Setting @{ FinOpsApplyVersion = 'true' }
        $global:FakeTenant.Calls.Clear()
        $null = Invoke-TestRun -Mode Apply -PlanFile $script:PlanPath -Setting @{ FinOpsApplyVersion = 'true' }
        @(Get-ApplyCalls)[0] | Should -BeLike '*/environments/fos/finopsversions/10.0.48.9/apply*'
    }

    It 'stops planned actions that the current settings no longer allow' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -FinOpsBuild '10.0.2645.136' -FinOpsVersions '[{"version":"10.0.48.9","releaseStage":"QualityUpdate"}]' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'))),
            (New-FakeEnv -Id 'uat' -Name 'UAT' -Apps @((New-FakeApp 'msdyn_b' 'B' '2.0' '1.0'), (New-FakeApp 'msdyn_c' 'C' '2.0' '1.0')))
        )
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir -Setting @{ FinOpsApplyVersion = 'true' }
        $global:FakeTenant.Calls.Clear()
        # Meanwhile an admin turned F&O apply off and excluded UAT.
        $r = Invoke-TestRun -Mode Apply -PlanFile $script:PlanPath -Setting @{ FinOpsApplyVersion = 'false'; EnvironmentExclude = 'UAT' }
        Get-ApplyCalls | Should -HaveCount 0
        @(Get-InstallCalls) | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/fos/applicationPackages/msdyn_a/install*'
        @($r.Report.results | Where-Object Result -eq 'Stopped') | Should -HaveCount 3
        ($r.Report.results | Where-Object Phase -eq 'FinOps').Detail | Should -Be 'finOpsApplyVersion is now false'
        $r.ExitCode | Should -Be 0
    }

    It 'stops unproven production actions when productionRing was turned on after the plan' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir -Setting @{ ProductionRing = 'false' }
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -Ring Production -PlanFile $script:PlanPath
        Get-InstallCalls | Should -HaveCount 0
        $r.Report.results[0].Result | Should -Be 'Stopped'
    }

    It 'fails the Plan run and sets no outputs when the plan cannot be written' {
        Reset-TestModuleState -HostKind AzureDevOps
        New-TwoRingTenant
        $blocker = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        Set-Content -Path $blocker -Value 'a file, not a folder'
        $r = Invoke-TestRun -Mode Plan -PlanFile (Join-Path $blocker 'plan.json')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Not -Match 'hasProductionActions'
    }

    It 'whatIf in Apply mode re-checks but changes nothing' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -PlanFile $script:PlanPath -Setting @{ WhatIf = 'true' }
        Get-InstallCalls | Should -HaveCount 0
        @($r.Report.results | Where-Object Result -eq 'WouldApply') | Should -HaveCount 2
    }

    It 'fails clearly when the plan file is missing' {
        Set-FakeTenant -Environments @()
        $r = Invoke-TestRun -Mode Apply -PlanFile (Join-Path $script:Dir 'nope.json')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Plan file not found'
    }

    It 'refuses a plan made for another tenant' {
        New-TwoRingTenant
        $null = Invoke-TestRun -Mode Plan -OutputDirectory $script:Dir
        $p = Get-Content -Raw $script:PlanPath | ConvertFrom-Json
        $p.tenantId = 'someone-else'
        $p | ConvertTo-Json -Depth 30 | Set-Content $script:PlanPath
        $global:FakeTenant.Calls.Clear()
        $r = Invoke-TestRun -Mode Apply -PlanFile $script:PlanPath
        $r.ExitCode | Should -Be 1
        Get-InstallCalls | Should -HaveCount 0
    }
}
