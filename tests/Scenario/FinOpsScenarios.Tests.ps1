# The 22 F&O scenarios that verified v2.4.3 and v2.4.4, now run end to end
# against the module. Every scenario plants a stale Anchor Solution
# (10.0.48.6 in the fake tenant) to prove it never drives a decision.

BeforeDiscovery {
    function V([string] $Version, [string] $Stage) { @{ version = $Version; releaseStage = $Stage } }
    function J($List) { ConvertTo-Json -InputObject @($List) -Compress -Depth 5 }
    $QU = 'QualityUpdate'; $GA = 'GeneralAvailability'; $PV = 'Preview'
    $s50 = 'pqu-schedule-50.md'; $broken = 'pqu-schedule-broken.md'; $ambig = 'pqu-schedule-ambiguous.md'

    $script:Scenarios = @(
        @{ Name = 'Incident: live 10.0.48 offered 49.3, PQU'; Expect = 'none'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.49.3' $QU)) }
        @{ Name = 'Incident list, VersionUpdate'; Expect = '10.0.49.3'; Live = '10.0.2645.136'; Scope = 'VersionUpdate'; Versions = (J (V '10.0.49.3' $QU)) }
        @{ Name = 'Two versions (bare array), PQU'; Expect = '10.0.48.9'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J @((V '10.0.48.9' $QU), (V '10.0.49.3' $QU))) }
        @{ Name = 'Two versions (bare array), VersionUpdate'; Expect = '10.0.49.3'; Live = '10.0.2645.136'; Scope = 'VersionUpdate'; Versions = (J @((V '10.0.48.9' $QU), (V '10.0.49.3' $QU))) }
        @{ Name = 'Two versions wrapped in value, PQU'; Expect = '10.0.48.9'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (ConvertTo-Json @{ value = @((V '10.0.48.9' $QU), (V '10.0.49.3' $QU)) } -Compress -Depth 5) }
        @{ Name = 'Post-incident: live 10.0.49, PQU 49.4'; Expect = '10.0.49.4'; Live = '10.0.2790.83'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.49.4' $QU)) }
        @{ Name = 'VersionUpdate never jumps two trains'; Expect = 'none'; Live = '10.0.2645.136'; Scope = 'VersionUpdate'; Versions = (J (V '10.0.50.1' $GA)); Schedule = $s50 }
        @{ Name = 'VersionUpdate never picks a preview'; Expect = 'none'; Live = '10.0.2645.136'; Scope = 'VersionUpdate'; Versions = (J (V '10.0.49.4' $PV)) }
        @{ Name = 'Any picks the highest'; Expect = '10.0.50.1'; Live = '10.0.2645.136'; Scope = 'Any'; Versions = (J @((V '10.0.49.3' $QU), (V '10.0.50.1' $GA), (V '10.0.49.4' $PV))) }
        @{ Name = 'Any never applies a lower train'; Expect = 'none'; Live = '10.0.2790.83'; Scope = 'Any'; Versions = (J (V '10.0.48.9' $QU)) }
        @{ Name = 'Any, explicit target on a lower train'; Expect = 'none'; Live = '10.0.2790.83'; Scope = 'Any'; Versions = (J @((V '10.0.48.9' $QU), (V '10.0.49.4' $QU))); Target = '10.0.48.9' }
        @{ Name = 'PQU, explicit target on the next train'; Expect = 'none'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J @((V '10.0.48.9' $QU), (V '10.0.49.3' $QU))); Target = '10.0.49.3' }
        @{ Name = 'Future 10.0.50 learned from the schedule'; Expect = '10.0.50.2'; Live = '10.0.2911.70'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.50.2' $QU)); Schedule = $s50 }
        @{ Name = 'VersionUpdate 49 to 50 via the schedule'; Expect = '10.0.50.1'; Live = '10.0.2790.83'; Scope = 'VersionUpdate'; Versions = (J @((V '10.0.49.4' $QU), (V '10.0.50.1' $GA))); Schedule = $s50 }
        @{ Name = '10.0.50 not yet in the schedule'; Expect = 'none'; Live = '10.0.2911.70'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.50.2' $QU)) }
        @{ Name = 'Schedule download fails, live 10.0.48'; Expect = '10.0.48.9'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.48.9' $QU)); ScheduleFails = $true }
        @{ Name = 'Schedule download fails, live 10.0.50'; Expect = 'none'; Live = '10.0.2911.70'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.50.2' $QU)); ScheduleFails = $true }
        @{ Name = 'Schedule page format changed'; Expect = '10.0.48.9'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.48.9' $QU)); Schedule = $broken }
        @{ Name = 'Ambiguous build in the schedule'; Expect = 'none'; Live = '10.0.2790.83'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.49.4' $QU)); Schedule = $ambig }
        @{ Name = 'Emergency finOpsBuildTrainMap override'; Expect = '10.0.50.2'; Live = '10.0.2911.70'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.50.2' $QU)); ScheduleFails = $true; BuildMap = '10.0.2911=50' }
        @{ Name = 'Virtual entity listed first, Dataverse fails'; Expect = '10.0.48.9'; Live = '10.0.2645.136'; Scope = 'QualityUpdate'; Versions = (J (V '10.0.48.9' $QU)); VirtualEntityFirst = $true; DataverseFails = $true }
        @{ Name = 'No applicationVersion reported'; Expect = 'none'; Live = ''; Scope = 'QualityUpdate'; Versions = (J (V '10.0.48.9' $QU)) }
    )
}

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
}

Describe 'Finance and Operations target selection (v2.4.4 scenarios)' {
    BeforeEach {
        Reset-TestModuleState
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { Invoke-FakeRequest @PesterBoundParameters }
    }

    It '<Name> -> <Expect>' -ForEach $script:Scenarios {
        $apps = @()
        if ($VirtualEntityFirst) { $apps += New-FakeApp -UniqueName 'msdyn_FnOVirtualEntityAnchor' -Name 'Finance and Operations Virtual Entity' -Available '1.0.0.9' -Installed '1.0.0.9' }
        $fakeEnv = New-FakeEnv -Id 'env1' -Name 'Dev01' -Apps $apps -FinOpsBuild $Live -FinOpsDeployment 'UnifiedDeveloper' -FinOpsVersions $Versions -SolutionsStatus $(if ($DataverseFails) { 401 } else { 200 })
        # Live = '' means the environment reports no applicationVersion, but
        # F&O is still installed (presence is what matters).
        if (-not $Live) { $fakeEnv.FinOpsBuild = ' ' }
        $sched = 'pqu-schedule.md'
        if ($Schedule) { $sched = $Schedule }
        Set-FakeTenant -Environments @($fakeEnv) -Schedule $sched -ScheduleFails:([bool]$ScheduleFails)

        $settings = @{ FinOpsApplyVersion = 'true'; FinOpsUpdateScope = $Scope }
        if ($Target) { $settings['FinOpsTargetVersion'] = $Target }
        if ($BuildMap) { $settings['FinOpsBuildTrainMap'] = $BuildMap }
        $r = Invoke-TestRun -Setting $settings

        $applied = @(Get-FakeCalls 'POST */finopsversions/*/apply*' | ForEach-Object { $_ -replace '.*finopsversions/([^/]+)/apply.*', '$1' })
        $got = 'none'
        if ($applied.Count -gt 0) { $got = $applied[0] }
        $got | Should -Be $Expect
        $applied.Count | Should -BeLessOrEqual 1
        $r.Output | Should -Not -Match 'Unmocked request'
    }
}
