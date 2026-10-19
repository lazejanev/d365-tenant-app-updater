# The results board (log) and the run summary (summary.md).

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
    function New-MixedTenant {
        Set-FakeTenant -Environments @(
            (New-FakeEnv -Id 'p' -Name 'Prod' -Sku 'Production' -Apps @((New-FakeApp 'msdyn_new' 'Brand New' '3.0' '2.0'))),
            (New-FakeEnv -Id 'd2' -Name 'Dev2' -Apps @((New-FakeApp 'msdyn_ok' 'Hub' '5.1' '5.0'), (New-FakeApp 'msdyn_same' 'Same' '1.0' '1.0'))),
            (New-FakeEnv -Id 'd10' -Name 'Dev10' -Apps @((New-FakeApp 'msdyn_bad' 'Broken' '2.0' '1.0')) -InstallResponses @{ msdyn_bad = @{ Status = 500; Body = @{ error = @{ code = 'X'; message = 'boom' } } } })
        )
    }
}

Describe 'Results board in the log' {
    BeforeEach {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'colours lines with Azure DevOps formatting, never with issue commands' {
        Reset-TestModuleState -HostKind AzureDevOps
        New-MixedTenant
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $board = $r.Output.Substring($r.Output.IndexOf('RESULTS (A'))
        $board | Should -Match ([regex]::Escape('##[section]  [UPDATED] Hub'))
        $board | Should -Match ([regex]::Escape('##[error]  [FAILED ] Broken'))
        $board | Should -Match ([regex]::Escape('##[debug]  [HELD   ] Brand New'))
        # Board lines colour only; the one real warning is the failed install itself.
        ([regex]::Matches($board, [regex]::Escape('##vso[task.logissue'))).Count | Should -Be 0
    }

    It 'uses ANSI colours on GitHub' {
        Reset-TestModuleState -HostKind GitHub
        New-MixedTenant
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $r.Output | Should -Match ([regex]::Escape("$([char]27)[32m  [UPDATED] Hub"))
        $r.Output | Should -Match ([regex]::Escape("$([char]27)[31m  [FAILED ] Broken"))
    }

    It 'lists environments A to Z with their counts' {
        Reset-TestModuleState
        New-MixedTenant
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $board = $r.Output.Substring($r.Output.IndexOf('RESULTS (A'))
        $board.IndexOf('Dev2  [NonProduction]') | Should -BeLessThan $board.IndexOf('Dev10  [NonProduction]')
        $board.IndexOf('Dev10  [NonProduction]') | Should -BeLessThan $board.IndexOf('Prod  [Production]')
        $board | Should -Match 'Dev2  \[NonProduction\]  1 updated, 1 up to date'
    }

    It 'shows PLANNED lines in a plan run' {
        Reset-TestModuleState
        New-MixedTenant
        $r = Invoke-TestRun -Mode Plan
        $r.Output | Should -Match 'PLAN \(A'
        $r.Output | Should -Match '\[PLANNED\] Hub'
    }
}

Describe 'Run summary (summary.md)' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It 'starts with the result and the counters' {
        New-MixedTenant
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $r.Summary | Should -Match '## ⚠️ d365-tenant-app-updater 3\.0\.\d+ · SucceededWithIssues'
        $r.Summary | Should -Match '\| \*\*1\*\* \| \*\*0\*\* \| \*\*0\*\* \| \*\*1\*\* \| \*\*0\*\* \| \*\*1\*\* \| \*\*1\*\* \|'
        $r.Report.counts.Updated | Should -Be 1
        $r.Report.counts.Held | Should -Be 1
    }

    It 'has one A to Z list with a status per row' {
        New-MixedTenant
        $r = Invoke-TestRun -Setting @{ WaitForInstallsMinutes = '5' }
        $rows = @($r.Summary -split "`n" | Where-Object { $_ -match '^\| (✅|❌|⏸️) [A-Za-z ]+ \| (Dev|Prod)' })
        $rows | Should -HaveCount 3
        $rows[0] | Should -Match 'Dev2'
        $rows[1] | Should -Match 'Dev10'
        $rows[2] | Should -Match 'Prod'
        $r.Summary | Should -Not -Match '<sub>'
    }

    It 'aligns columns and says no for environments without F&O' {
        New-MixedTenant
        $r = Invoke-TestRun -Mode Plan
        # Held shows (Prod holds an app); Excluded and No match are 0 everywhere, so hidden.
        $r.Summary | Should -Match ([regex]::Escape('| :---: | :--- | :--- | :---: | :---: | :---: | :---: |'))
        $r.Summary | Should -Match ([regex]::Escape('|  | Environment | Ring | Updates | Held | Up to date | F&O |'))
        $r.Summary | Should -Match '\| Dev2 \| NonProduction \| 1 \| 0 \| 1 \| no \|'
        $r.Summary | Should -Not -Match '\| --- \|'
    }

    It 'shows Excluded and No match only when an environment has one' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '2.0' '1.0'), (New-FakeApp 'msdyn_x' 'X' '2.0' '1.0'), (New-FakeApp 'msdyn_n' 'N' '2.0' ''))))
        $r = Invoke-TestRun -Mode Plan -Setting @{ AppExclude = 'msdyn_x' }
        $r.Summary | Should -Match ([regex]::Escape('|  | Environment | Ring | Updates | Up to date | Excluded | No match | F&O |'))
    }

    It 'shows a retry of a failed install as Retry, without an installed version' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'Agent' '2.0' '' -State 'InstallFailed'))))
        $r = Invoke-TestRun -Mode Plan
        $r.Summary | Should -Match '\| 🔁 Retry planned \| E \| NonProduction \| Agent \|   \| 2\.0 \| Last install failed in Power Platform'
        $r.Output | Should -Match '\[RETRY  \] Agent'
        $r.Report.counts.Planned | Should -Be 1
    }

    It 'gives every F&O environment a status in the table instead of a list under it' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'fo' -Name 'FO' -FinOpsBuild '10.0.2645.136' -FinOpsDeployment 'LCSSandbox'))
        $r = Invoke-TestRun -Mode Plan -Setting @{ FinOpsApplyVersion = 'true' }
        $r.Summary | Should -Match '\| FO \| NonProduction \| 10\.0\.2645\.136 \|.*\| LCS managed \|'
        $r.Summary | Should -Not -Match '(?m)^- \*\*FO\*\*'
        $r.Summary | Should -Not -Match 'Offered'
    }

    It 'names each stage summary on the Azure DevOps run page' {
        Reset-TestModuleState -HostKind AzureDevOps
        New-MixedTenant
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('d365tau-' + [guid]::NewGuid().ToString('N'))
        $p = Invoke-TestRun -Mode Plan -OutputDirectory $dir
        $p.Output | Should -Match ([regex]::Escape('1. Plan - what was found and decided.md'))
        $a = Invoke-TestRun -Mode Apply -Ring NonProduction -PlanFile (Join-Path $dir 'plan.json')
        $a.Output | Should -Match ([regex]::Escape('2. Apply non-production - what was started.md'))
        # The Apply summary reports what it did; the inventory stays in the Plan summary.
        $a.Summary | Should -Not -Match 'Environments \(A'
        $a.Summary | Should -Match 'in the \*\*Plan\*\* summary'
        @(Get-ChildItem $a.Dir -Filter '*.md').Name | Should -Be @('summary.md')
    }

    It 'says so when there is nothing to update' {
        Set-FakeTenant -Environments @((New-FakeEnv -Id 'e' -Name 'E' -Apps @((New-FakeApp 'msdyn_a' 'A' '1.0' '1.0'))))
        $r = Invoke-TestRun
        $r.Summary | Should -Match 'Nothing to update'
    }
}
