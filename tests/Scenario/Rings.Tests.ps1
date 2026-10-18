# Production ring: production only takes a version a non-production
# environment already runs.

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force

    function Get-InstallCalls { @(Get-FakeCalls 'POST */applicationPackages/*/install*') }
    function Get-ApplyCalls { @(Get-FakeCalls 'POST */finopsversions/*/apply*') }
    function Get-Iso([int] $DaysAgo) { (Get-Date).ToUniversalTime().AddDays(-$DaysAgo).ToString('o') }
}

Describe 'Production ring for apps' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'holds production while non-production is still on the old version, and updates non-production' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Contoso Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'Contoso UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0')))
        )
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/uat/*'
        $held = @($r.Report.decisions | Where-Object Code -eq 'HeldForProduction')
        $held | Should -HaveCount 1
        $held[0].EnvironmentName | Should -Be 'Contoso Prod'
        $r.Summary | Should -Match 'Held for production'
        $r.ExitCode | Should -Be 0
    }

    It 'updates production once a non-production environment runs the version' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Contoso Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'Contoso UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '2.0.0.0')))
        )
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/prod/*'
        ($r.Report.actions | Where-Object EnvironmentId -eq 'prod').Reason | Should -Be 'already runs in Contoso UAT'
    }

    It 'counts a non-production environment that runs a NEWER version as proof' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'dev' -Name 'Dev' -Sku 'Developer' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '3.0.0.0' '2.5.0.0')))
        )
        $null = Invoke-TestRun -Setting @{ EnvironmentFilter = 'Prod,Dev' }
        @(Get-InstallCalls | Where-Object { $_ -like '*/environments/prod/*' }) | Should -HaveCount 1
    }

    It 'holds an app that no non-production environment has installed' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Field' 'Field Service' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'dev' -Name 'Dev' -Sku 'Sandbox' -Apps @())
        )
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 0
        ($r.Report.decisions | Where-Object Code -eq 'HeldForProduction').Reason | Should -Match 'not installed in any non-production'
    }

    It 'applies productionSoakDays using the solution modifiedon date' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '2.0.0.0' -ModifiedOn (Get-Iso 1))))
        )
        $r = Invoke-TestRun -Setting @{ ProductionSoakDays = '3' }
        Get-InstallCalls | Should -HaveCount 0
        ($r.Report.decisions | Where-Object Code -eq 'HeldForProduction').Reason | Should -Match 'less than 3 day'

        $global:FakeTenant.Environments[1].Apps[0].ModifiedOn = (Get-Iso 10)
        $global:FakeTenant.Calls.Clear()
        $null = Invoke-TestRun -Setting @{ ProductionSoakDays = '3' }
        Get-InstallCalls | Should -HaveCount 1
    }

    It 'updates production directly when productionRing = false' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'prod' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0')))
        )
        $null = Invoke-TestRun -Setting @{ ProductionRing = 'false' }
        Get-InstallCalls | Should -HaveCount 2
    }

    It 'treats environments named in productionEnvironments as production' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'train' -Name 'Training' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 'uat' -Name 'UAT' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0')))
        )
        $r = Invoke-TestRun -Setting @{ ProductionEnvironments = 'training' }
        ($r.Report.environments | Where-Object Environment -eq 'Training').Ring | Should -Be 'Production'
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/uat/*'
    }

    It 'uses productionEnvironmentTypes to decide which environment types are production' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'p' -Name 'P' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0'))),
            (New-FakeEnv -Id 's' -Name 'S' -Sku 'Sandbox' -Apps @((New-FakeApp 'msdyn_Sales' 'Sales' '2.0.0.0' '1.0.0.0')))
        )
        $r = Invoke-TestRun -Setting @{ ProductionEnvironmentTypes = 'Production,Sandbox' }
        Get-InstallCalls | Should -HaveCount 0
        @($r.Report.environments | Where-Object Ring -eq 'Production') | Should -HaveCount 2
    }
}

Describe 'Production ring for Finance and Operations' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
        $script:Offer = '[{"version":"10.0.48.9","releaseStage":"QualityUpdate"}]'
    }

    It 'holds production while the sandbox has not taken the PQU, and applies it to the sandbox' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'fop' -Name 'FO Prod' -Sku 'Production' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'UnifiedProduction' -FinOpsVersions $script:Offer),
            (New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -Sku 'Sandbox' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'UnifiedSandbox' -FinOpsVersions $script:Offer)
        )
        $r = Invoke-TestRun -Setting @{ FinOpsApplyVersion = 'true' }
        Get-ApplyCalls | Should -HaveCount 1
        @(Get-ApplyCalls)[0] | Should -BeLike '*/environments/fos/*'
        ($r.Report.decisions | Where-Object { $_.Phase -eq 'FinOps' -and $_.Code -eq 'HeldForProduction' }).EnvironmentName | Should -Be 'FO Prod'
    }

    It 'applies to production once the sandbox no longer lists the version (it already has it)' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'fop' -Name 'FO Prod' -Sku 'Production' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'UnifiedProduction' -FinOpsVersions $script:Offer),
            (New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -Sku 'Sandbox' -FinOpsBuild '10.0.2645.158' -FinOpsDeployment 'UnifiedSandbox' -FinOpsVersions '[]')
        )
        $null = Invoke-TestRun -Setting @{ FinOpsApplyVersion = 'true' }
        Get-ApplyCalls | Should -HaveCount 1
        @(Get-ApplyCalls)[0] | Should -BeLike '*/environments/fop/finopsversions/10.0.48.9/apply*'
    }

    It 'counts a sandbox on a higher release train as proof' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'fop' -Name 'FO Prod' -Sku 'Production' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'UnifiedProduction' -FinOpsVersions $script:Offer),
            (New-FakeEnv -Id 'fos' -Name 'FO Sandbox' -Sku 'Sandbox' -FinOpsBuild '10.0.2790.83' -FinOpsDeployment 'UnifiedSandbox' -FinOpsVersions '[]')
        )
        $null = Invoke-TestRun -Setting @{ FinOpsApplyVersion = 'true' }
        @(Get-ApplyCalls)[0] | Should -BeLike '*/environments/fop/*'
    }

    It 'makes an environment production from its F&O deployment type' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'fop' -Name 'FO Prod' -Sku 'Sandbox' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'UnifiedProduction' -FinOpsVersions $script:Offer)
        )
        $r = Invoke-TestRun -Setting @{ FinOpsApplyVersion = 'true' }
        Get-ApplyCalls | Should -HaveCount 0
        ($r.Report.environments | Select-Object -First 1).Ring | Should -Be 'Production'
        ($r.Report.decisions | Where-Object Phase -eq 'FinOps').Reason | Should -Match 'no non-production F&O environment in scope'
    }
}
