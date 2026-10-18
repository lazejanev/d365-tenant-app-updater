# Guards for the Azure DevOps YAML. CI cannot run Azure DevOps, so these
# check the things that break a run before it starts.

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
}

Describe 'Azure DevOps pipelines' {
    It '<File> needs no Azure DevOps environment by default' -ForEach @(@{ File = 'azure-pipelines.yml' }, @{ File = 'azure-pipelines-federated.yml' }) {
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

    It 'falls back to a normal job when no approval environment is set' {
        $t = Get-Content -Raw (Join-Path $global:RepoRoot 'pipelines/templates/updater-stages.yml')
        $t | Should -Match "if or\(eq\(parameters\.productionApprovalEnvironment, ''\), eq\(parameters\.productionApprovalEnvironment, 'none'\)\)"
        $t | Should -Match '- job: Apply'
    }
}
