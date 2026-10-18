# A to Z ordering: natural, case-insensitive, and identical on every agent
# (Windows or Linux, any locale).

BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
}

Describe 'Sort order' {
    It 'puts numbers in numeric order and ignores case' {
        InModuleScope D365TenantAppUpdater {
            $n = 'Dev10', 'dev2', 'Dev1', 'UAT', 'alpha', 'Contoso Prod'
            (Sort-Items $n @({ $_ })) | Should -Be @('alpha', 'Contoso Prod', 'Dev1', 'dev2', 'Dev10', 'UAT')
        }
    }

    It 'treats -, _, . and spaces alike' {
        InModuleScope D365TenantAppUpdater {
            Get-SortKey 'Contoso-Dev_01.EU' | Should -Be (Get-SortKey 'contoso dev 1 eu')
        }
    }

    It 'gives the same order under any culture (<Culture>)' -ForEach @(@{ Culture = 'en-US' }, @{ Culture = 'tr-TR' }, @{ Culture = 'sv-SE' }, @{ Culture = 'ja-JP' }) {
        InModuleScope D365TenantAppUpdater -Parameters @{ Culture = $Culture } {
            param($Culture)
            $saved = [System.Globalization.CultureInfo]::CurrentCulture
            try {
                [System.Globalization.CultureInfo]::CurrentCulture = [System.Globalization.CultureInfo]::new($Culture)
                $n = 'Ivy Prod', 'iris dev', 'Aa test', 'Zz', 'Öland', 'Dev_UAT', 'dev-test', 'Dev2', 'Dev10'
                (Sort-Items $n @({ $_ })) -join '|' | Should -Be 'Aa test|dev-test|Dev_UAT|Dev2|Dev10|iris dev|Ivy Prod|Zz|Öland'
            }
            finally { [System.Globalization.CultureInfo]::CurrentCulture = $saved }
        }
    }

    It 'is stable: equal keys keep their original order' {
        InModuleScope D365TenantAppUpdater {
            $o = @([pscustomobject]@{ N = 'Dev'; Id = 2 }, [pscustomobject]@{ N = 'dev'; Id = 1 })
            (Sort-Items $o @({ $_.N }) | ForEach-Object Id) | Should -Be @(2, 1)
        }
    }

    It 'breaks display-name ties by environment id' {
        InModuleScope D365TenantAppUpdater {
            $e = @([pscustomobject]@{ DisplayName = 'Sandbox'; Id = 'b' }, [pscustomobject]@{ DisplayName = 'sandbox'; Id = 'a' })
            (Sort-ByDisplayName $e | ForEach-Object Id) | Should -Be @('a', 'b')
        }
    }
}
