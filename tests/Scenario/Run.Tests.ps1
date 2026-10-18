# Whole-run behaviour: ordering, discovery, failures, install handling,
# polling, exclusions, exit codes.

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
    function Get-InstallCalls { @(Get-FakeCalls 'POST */applicationPackages/*/install*') }
}

Describe 'Ordering (A to Z)' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'processes environments and apps alphabetically, ignoring case and API order' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'z' -Name 'Zeta' -Apps @((New-FakeApp 'msdyn_b' 'beta app' '2.0' '1.0'), (New-FakeApp 'msdyn_a' 'Alpha app' '2.0' '1.0'))),
            (New-FakeEnv -Id 'a' -Name 'alpha' -Apps @((New-FakeApp 'msdyn_a' 'Alpha app' '2.0' '1.0'))),
            (New-FakeEnv -Id 'b' -Name 'Beta' -Apps @((New-FakeApp 'msdyn_a' 'Alpha app' '2.0' '1.0')))
        )
        $r = Invoke-TestRun
        $order = @(Get-InstallCalls | ForEach-Object { if ($_ -match '/environments/([^/]+)/applicationPackages/([^/]+)/') { "$($Matches[1]):$($Matches[2])" } })
        $order | Should -Be @('a:msdyn_a', 'b:msdyn_a', 'z:msdyn_a', 'z:msdyn_b')
        @($r.Report.environments | ForEach-Object Environment) | Should -Be @('alpha', 'Beta', 'Zeta')
        $r.Output.IndexOf('ENVIRONMENT: alpha') | Should -BeLessThan $r.Output.IndexOf('ENVIRONMENT: Beta')
        $r.Output.IndexOf('ENVIRONMENT: Beta') | Should -BeLessThan $r.Output.IndexOf('ENVIRONMENT: Zeta')
    }

    It 'applies non-production before production' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'p' -Name 'Alpha Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'))),
            (New-FakeEnv -Id 's' -Name 'Zulu Sandbox' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')))
        )
        $null = Invoke-TestRun -Setting @{ ProductionRing = 'false' }
        @(Get-InstallCalls)[0] | Should -BeLike '*/environments/s/*'
        @(Get-InstallCalls)[1] | Should -BeLike '*/environments/p/*'
    }
}

Describe 'Discovery and sign-in' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'follows nextLink paging' {
        Set-FakeTenant -PageSize 2 -Environments @(
            (New-FakeEnv -Id 'e1' -Name 'E1'), (New-FakeEnv -Id 'e2' -Name 'E2'), (New-FakeEnv -Id 'e3' -Name 'E3')
        )
        $r = Invoke-TestRun -Mode Plan
        @($r.Report.environments) | Should -HaveCount 3
    }

    It 'skips environments without Dataverse and applies filter and exclude' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'e1' -Name 'Keep'), (New-FakeEnv -Id 'e2' -Name 'Drop'), (New-FakeEnv -Id 'e3' -Name 'NoDv' -NoDataverse), (New-FakeEnv -Id 'e4' -Name 'Other')
        )
        $r = Invoke-TestRun -Mode Plan -Setting @{ EnvironmentFilter = 'Keep, Drop, NoDv'; EnvironmentExclude = 'drop' }
        @($r.Report.environments | ForEach-Object Environment) | Should -Be @('Keep')
    }

    It 'fails the run when environments cannot be listed' {
        Set-FakeTenant -Environments @() -BapStatus 403
        $r = Invoke-TestRun
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Could not list environments: HTTP 403'
    }

    It 'fails the run when sign-in fails' {
        Set-FakeTenant -Environments @() -TokenStatus 401
        $r = Invoke-TestRun
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'Invalid client secret'
    }

    It 'fails the run when no client id is given' {
        Set-FakeTenant -Environments @()
        $out = & { Invoke-D365TenantAppUpdate -TenantId 't' -ClientSecret 's' -OutputDirectory ([IO.Path]::GetTempPath()) } 6>&1
        @($out | Where-Object { $_ -is [int] })[-1] | Should -Be 1
    }

    It 'returns exactly one exit code and nothing else on the pipeline' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e1' -Name 'E1' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'))))
        $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
        $out = @(Invoke-D365TenantAppUpdate -ClientId c -ClientSecret s -TenantId t -OutputDirectory $dir -Setting @{ WaitForInstallsMinutes = '0' } 6>$null)
        $out | Should -HaveCount 1
        $out[0] | Should -BeOfType [int]
    }
}

Describe 'Partial failures' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'keeps going when one environment cannot be read, and ends with issues' {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'bad' -Name 'Bad' -SolutionsStatus 403 -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'))),
            (New-FakeEnv -Id 'good' -Name 'Good' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')))
        )
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 1
        $r.Report.result | Should -Be 'SucceededWithIssues'
        $r.ExitCode | Should -Be 0
        $r.Summary | Should -Match 'Needs attention'
    }

    It 'returns 1 for issues when failOnIssues = true, but never fails the Plan stage for them' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'bad' -Name 'Bad' -PackagesStatus 500))
        $r = Invoke-TestRun -Setting @{ FailOnIssues = 'true' }
        $r.ExitCode | Should -Be 1
        $r = Invoke-TestRun -Mode Plan -Setting @{ FailOnIssues = 'true' }
        $r.ExitCode | Should -Be 0
        $r.Report.result | Should -Be 'SucceededWithIssues'
    }

    It 'reports a failed PAC CLI fallback as manual, not started' {
        function global:pac { $global:LASTEXITCODE = 1; 'pac: something went wrong' }
        try {
            Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')) -InstallResponses @{ msdyn_a = @{ Status = 400; Body = @{ error = @{ code = 'X'; message = 'This application requires a custom install experience.' } } } }))
            $r = Invoke-TestRun -Setting @{ UsePacFallback = 'true'; AuthMode = 'ClientSecret' }
            $r.Report.results[0].Result | Should -Be 'Manual'
        }
        finally { Remove-Item function:global:pac -ErrorAction SilentlyContinue }
    }

    It 'marks Azure DevOps runs with issues as SucceededWithIssues' {
        Reset-TestModuleState -HostKind AzureDevOps
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'bad' -Name 'Bad' -PackagesStatus 500))
        $r = Invoke-TestRun
        $r.Output | Should -Match ([regex]::Escape('##vso[task.complete result=SucceededWithIssues;]'))
        $r.ExitCode | Should -Be 0
    }

    It 'reports a failed install' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')) -InstallResponses @{ msdyn_a = @{ Status = 500; Body = @{ error = @{ code = 'InternalError'; message = 'Something broke.' } } } }))
        $r = Invoke-TestRun
        $r.Report.results[0].Result | Should -Be 'Failed'
        $r.Report.results[0].Detail | Should -Match 'Something broke'
        $r.Report.result | Should -Be 'SucceededWithIssues'
    }

    It 'stops installing in an environment in Admin Mode' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'), (New-FakeApp 'msdyn_b' 'B' '2.0' '1.0')) -InstallResponses @{ msdyn_a = @{ Status = 400; Body = @{ error = @{ code = 'EnvironmentNotEnabled'; message = 'The environment is not enabled (admin mode).' } } } }))
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 1
        @($r.Report.results | ForEach-Object Result) | Should -Be @('AdminMode', 'AdminMode')
    }

    It 'reports apps that need the admin center install wizard, not as failures' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')) -InstallResponses @{ msdyn_a = @{ Status = 400; Body = @{ error = @{ code = 'X'; message = 'This application requires a custom install experience.' } } } }))
        $r = Invoke-TestRun
        $r.Report.results[0].Result | Should -Be 'Manual'
        $r.Report.result | Should -Be 'Succeeded'
    }
}

Describe 'App selection' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'never installs when the installed version is unknown, equal or newer' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @(
            (New-FakeApp 'msdyn_nomatch' 'No match' '2.0' ''),
            (New-FakeApp 'msdyn_same' 'Same' '2.0' '2.0'),
            (New-FakeApp 'msdyn_newer' 'Newer' '2.0' '3.0')
        )))
        $r = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 0
        @($r.Report.decisions | ForEach-Object Code | Sort-Object) | Should -Be @('NoSolutionMatch', 'UpToDate', 'UpToDate')
    }

    It 'retries a failed install, unless retryFailedInstalls = false' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '' -State 'InstallFailed'))))
        $null = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 1
        $global:FakeTenant.Calls.Clear()
        $null = Invoke-TestRun -Setting @{ RetryFailedInstalls = 'false' }
        Get-InstallCalls | Should -HaveCount 0
    }

    It 'never touches the F&O provisioning app in the apps phase' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -FinOpsBuild '10.0.2645.136'))
        $null = Invoke-TestRun
        Get-InstallCalls | Should -HaveCount 0
    }

    It 'excludes apps by exact name, by wildcard, and (deprecated) by part of the name' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @(
            (New-FakeApp 'msdyn_exact' 'Exact App' '2.0' '1.0'),
            (New-FakeApp 'msdyn_wild_x' 'Wild App' '2.0' '1.0'),
            (New-FakeApp 'msdyn_portalpart' 'Portal Part' '2.0' '1.0'),
            (New-FakeApp 'msdyn_kept' 'Kept' '2.0' '1.0')
        )))
        $r = Invoke-TestRun -Setting @{ AppExclude = 'msdyn_exact, msdyn_wild_*, portal' }
        Get-InstallCalls | Should -HaveCount 1
        @(Get-InstallCalls)[0] | Should -BeLike '*/msdyn_kept/install*'
        @($r.Report.warnings | Where-Object { $_ -match "appExclude 'portal'.*deprecated" }) | Should -HaveCount 1
        @($r.Report.warnings | Where-Object { $_ -match 'msdyn_exact|msdyn_wild' }) | Should -HaveCount 0
    }

    It 'warns about retired variables' {
        $env:UpdateFinOpsVersion = 'true'
        Set-FakeTenant -Environments @()
        $r = Invoke-TestRun -Mode Plan
        @($r.Report.warnings | Where-Object { $_ -match 'UpdateFinOpsVersion' }) | Should -HaveCount 1
    }
}

Describe 'Waiting for app installs' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
        $global:FakeNow = [datetime]::new(2026, 10, 18, 2, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName D365TenantAppUpdater Get-Now { $global:FakeNow = $global:FakeNow.AddMinutes(1); $global:FakeNow }
    }

    It 'records <Status> as <Expected>' -ForEach @(
        @{ Status = 'Succeeded'; Expected = 'Succeeded'; Result = 'Succeeded' }
        @{ Status = 'Failed'; Expected = 'Failed'; Result = 'SucceededWithIssues' }
        @{ Status = 'Running'; Expected = 'TimedOut'; Result = 'Succeeded' }
    ) {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0')) -OperationStatus $Status))
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $r.Report.results[0].Result | Should -Be $Expected
        $r.Report.result | Should -Be $Result
        @(Get-FakeCalls 'GET */operations/op-msdyn_a*').Count | Should -BeGreaterThan 0
    }

    It 'does not poll when waitForInstallsMinutes = 0' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'))))
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '0' }
        @(Get-FakeCalls 'GET */operations/*') | Should -HaveCount 0
        $r.Report.results[0].Result | Should -Be 'Started'
    }
}
