# Guards for the Azure DevOps YAML. CI cannot run Azure DevOps, so these
# check the things that break a run before it starts.

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
}

Describe 'Azure DevOps pipelines' {
    It '<File> needs no Azure DevOps environment by default' -ForEach @(@{ File = 'azure-pipelines.yml' }, @{ File = 'pipelines/azure-pipelines-federated.yml' }) {
        # Azure DevOps does not create environments for YAML that arrives
        # through a git sync: a default environment name fails every run at
        # queue time ("Environment ... could not be found").
        $text = Get-Content -Raw (Join-Path $global:RepoRoot $File)
        $text | Should -Match "(?ms)- name: productionApprovalEnvironment\s+displayName: [^\n]+\s+type: string\s+default: none"
        $text | Should -Match 'productionApprovalEnvironment: \$\{\{ parameters\.productionApprovalEnvironment \}\}'
    }

    It 'references an environment only through the opt-in parameter' {
        foreach ($f in Get-ChildItem (Join-Path $global:RepoRoot 'pipelines') -Recurse -Filter *.yml) {
            foreach ($line in (Get-Content $f.FullName | Where-Object { $_ -match '^\s*environment:' })) {
                $line | Should -Match 'parameters\.productionApprovalEnvironment' -Because "$($f.Name) must not hard-wire an environment"
            }
        }
    }

    It 'every template reference points to an existing file (<File>)' -ForEach @(
        @{ File = 'azure-pipelines.yml' }, @{ File = 'pipelines/azure-pipelines-federated.yml' },
        @{ File = 'pipelines/templates/stages.yml' }, @{ File = 'pipelines/templates/run-updater.yml' }) {
        # Azure DevOps resolves a template path relative to the file that uses it.
        $path = Join-Path $global:RepoRoot $File
        foreach ($m in [regex]::Matches((Get-Content -Raw $path), '(?m)^\s*-\s*template:\s*(\S+)')) {
            Join-Path (Split-Path $path -Parent) $m.Groups[1].Value | Should -Exist
        }
    }

    It 'keeps the root paths existing Azure DevOps pipelines point at' {
        foreach ($f in 'azure-pipelines.yml', 'sync-from-github.yml', 'scripts/Update-TenantApps.ps1') {
            Join-Path $global:RepoRoot $f | Should -Exist
        }
    }

    It 'falls back to a normal job when no approval environment is set' {
        $t = Get-Content -Raw (Join-Path $global:RepoRoot 'pipelines/templates/stages.yml')
        $t | Should -Match "if or\(eq\(parameters\.productionApprovalEnvironment, ''\), eq\(parameters\.productionApprovalEnvironment, 'none'\)\)"
        $t | Should -Match '- job: Apply'
    }
}

Describe 'Secrets in the pipelines' {
    It 'never passes the client secret on the command line (Azure DevOps)' {
        $t = Get-Content -Raw (Join-Path $global:RepoRoot 'pipelines/templates/run-updater.yml')
        $t | Should -Not -Match '-ClientSecret'
        $t | Should -Match 'D365_CLIENT_SECRET: \$\(ClientSecret\)'
    }

    It 'gives the client secret only to the steps that sign in (GitHub)' {
        $t = Get-Content -Raw (Join-Path $global:RepoRoot '.github/workflows/tenant-app-updater.yml')
        ([regex]::Matches($t, 'D365_CLIENT_SECRET: \$\{\{ secrets\.D365_CLIENT_SECRET \}\}')).Count | Should -Be 3
        $t | Should -Not -Match '(?m)^  D365_CLIENT_SECRET:'
    }
}
