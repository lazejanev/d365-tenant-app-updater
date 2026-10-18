BeforeAll {
    . (Join-Path $PSScriptRoot '../TestHelpers.ps1')
    Import-Module $global:ModuleManifest -Force
}

Describe 'Host adapter' {
    BeforeEach { Reset-TestModuleState }

    It 'detects the host from the platform variables' {
        InModuleScope D365TenantAppUpdater {
            $script:HostKind = $null; $env:GITHUB_ACTIONS = 'true'
            Get-HostKind | Should -Be 'GitHub'
            $script:HostKind = $null; $env:GITHUB_ACTIONS = $null; $env:TF_BUILD = 'True'
            Get-HostKind | Should -Be 'AzureDevOps'
            $script:HostKind = $null; $env:TF_BUILD = $null
            Get-HostKind | Should -Be 'Local'
        }
    }

    It 'writes <Kind> warnings in the platform format' -ForEach @(
        @{ Kind = 'GitHub'; Expected = '::warning::a b' }
        @{ Kind = 'AzureDevOps'; Expected = '##vso[task.logissue type=warning]a b' }
        @{ Kind = 'Local'; Expected = 'WARNING: a b' }
    ) {
        InModuleScope D365TenantAppUpdater -Parameters @{ Kind = $Kind; Expected = $Expected } {
            param($Kind, $Expected)
            Set-HostKind $Kind
            $out = (Write-RunWarning "a`nb") 6>&1
            [string]$out | Should -Be $Expected
        }
    }

    It 'returns exit codes per result' {
        InModuleScope D365TenantAppUpdater {
            Set-HostKind Local
            Complete-Run -Result Succeeded | Should -Be 0
            Complete-Run -Result SucceededWithIssues | Should -Be 0
            Complete-Run -Result SucceededWithIssues -FailOnIssues $true | Should -Be 1
            Complete-Run -Result Failed | Should -Be 1
        }
    }
}

Describe 'Sign-in' {
    BeforeEach {
        Reset-TestModuleState
        Set-FakeTenant -Environments @()
    }

    It 'uses the client secret when no OIDC token source exists' {
        InModuleScope D365TenantAppUpdater {
            (Resolve-AuthMode -Settings (Get-RunSettings -Bound @{ ClientSecret = 's' })).Mode | Should -Be 'ClientSecret'
        }
    }

    It 'prefers GitHub OIDC over a secret in Auto mode' {
        InModuleScope D365TenantAppUpdater {
            $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.example/x?a=1'; $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'rt'
            $m = Resolve-AuthMode -Settings (Get-RunSettings -Bound @{ ClientSecret = 's' })
            $m.Mode | Should -Be 'Federated'; $m.Source | Should -Be 'GitHub'
        }
    }

    It 'resolves Azure DevOps federation only with a service connection id' {
        InModuleScope D365TenantAppUpdater {
            $env:SYSTEM_OIDCREQUESTURI = 'https://dev.azure.com/o/p/_apis/x/oidctoken'; $env:SYSTEM_ACCESSTOKEN = 'at'
            { Resolve-AuthMode -Settings (Get-RunSettings) } | Should -Throw '*No way to sign in*'
            $m = Resolve-AuthMode -Settings (Get-RunSettings -Bound @{ ServiceConnectionId = 'sc-1' })
            $m.Mode | Should -Be 'Federated'; $m.Source | Should -Be 'AzureDevOps'
        }
    }

    It 'explains how to fix authMode = Federated without a token source' {
        InModuleScope D365TenantAppUpdater {
            { Resolve-AuthMode -Settings (Get-RunSettings -Bound @{ AuthMode = 'Federated'; ClientSecret = 's' }) } | Should -Throw '*id-token: write*'
        }
    }

    It 'sends a GitHub OIDC assertion instead of a secret' {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest {
            $u = [string]$Uri
            if ($u -like 'https://token.actions.example/*') { return [pscustomobject]@{ StatusCode = 200; Content = '{"value":"gh-jwt"}'; Headers = @{} } }
            return [pscustomobject]@{ StatusCode = 200; Content = '{"access_token":"tok","expires_in":3600}'; Headers = @{} }
        }
        InModuleScope D365TenantAppUpdater {
            $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.example/x?a=1'; $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'rt'
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't'; ClientSecret = 'must-not-be-sent' }
            $null = Initialize-Auth -Settings $s
            Get-AccessToken -Settings $s -Scope 'x/.default' | Should -Be 'tok'
        }
        Should -Invoke -ModuleName D365TenantAppUpdater Invoke-WebRequest -ParameterFilter { $Uri -like 'https://token.actions.example/x?a=1&audience=api%3A%2F%2FAzureADTokenExchange' }
        Should -Invoke -ModuleName D365TenantAppUpdater Invoke-WebRequest -ParameterFilter { $Uri -like '*oauth2*' -and $Body -match 'client_assertion=gh-jwt' -and $Body -notmatch 'client_secret' }
    }

    It 'falls back to the client secret when federated sign-in is refused (authMode = Auto)' {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest {
            $u = [string]$Uri
            if ($u -like 'https://token.actions.example/*') { return [pscustomobject]@{ StatusCode = 200; Content = '{"value":"gh-jwt"}'; Headers = @{} } }
            if ($Body -match 'client_assertion=') { return [pscustomobject]@{ StatusCode = 400; Content = '{"error":"invalid_client","error_description":"AADSTS70021: No matching federated identity record found."}'; Headers = @{} } }
            return [pscustomobject]@{ StatusCode = 200; Content = '{"access_token":"secret-tok","expires_in":3600}'; Headers = @{} }
        }
        InModuleScope D365TenantAppUpdater {
            $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.example/x'; $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'rt'
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't'; ClientSecret = 's' }
            $null = Initialize-Auth -Settings $s
            $out = @(Get-AccessToken -Settings $s -Scope 'x/.default' 6>&1)
            $out[-1] | Should -Be 'secret-tok'
            ($out -join ' ') | Should -Match 'No matching federated identity record'
            $script:AuthState.Mode | Should -Be 'ClientSecret'
        }
    }

    It 'does not switch to the secret when a later token (one environment) is refused' {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest {
            $u = [string]$Uri
            if ($u -like 'https://token.actions.example/*') { return [pscustomobject]@{ StatusCode = 200; Content = '{"value":"gh-jwt"}'; Headers = @{} } }
            if ($Body -match 'scope=dv') { return [pscustomobject]@{ StatusCode = 400; Content = '{"error":"invalid_resource","error_description":"AADSTS500011"}'; Headers = @{} } }
            return [pscustomobject]@{ StatusCode = 200; Content = '{"access_token":"tok","expires_in":3600}'; Headers = @{} }
        }
        InModuleScope D365TenantAppUpdater {
            $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.example/x'; $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'rt'
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't'; ClientSecret = 's' }
            $null = Initialize-Auth -Settings $s
            $null = Get-AccessToken -Settings $s -Scope 'bap'
            { Get-AccessToken -Settings $s -Scope 'dv' } | Should -Throw '*AADSTS500011*'
            $script:AuthState.Mode | Should -Be 'Federated'
        }
    }

    It 'does not fall back when authMode = Federated' {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest {
            $u = [string]$Uri
            if ($u -like 'https://token.actions.example/*') { return [pscustomobject]@{ StatusCode = 200; Content = '{"value":"gh-jwt"}'; Headers = @{} } }
            return [pscustomobject]@{ StatusCode = 400; Content = '{"error":"invalid_client","error_description":"AADSTS70021"}'; Headers = @{} }
        }
        InModuleScope D365TenantAppUpdater {
            $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://token.actions.example/x'; $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'rt'
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't'; ClientSecret = 's'; AuthMode = 'Federated' }
            $null = Initialize-Auth -Settings $s
            { Get-AccessToken -Settings $s -Scope 'x/.default' } | Should -Throw '*AADSTS70021*'
        }
    }

    It 'caches tokens per scope and renews them before they expire' {
        $global:FakeNow = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName D365TenantAppUpdater Get-Now { $global:FakeNow }
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"access_token":"tok","expires_in":3600}'; Headers = @{} } }
        InModuleScope D365TenantAppUpdater {
            $s = Get-RunSettings -Bound @{ ClientId = 'c'; TenantId = 't'; ClientSecret = 's' }
            $null = Get-AccessToken -Settings $s -Scope 'a'
            $null = Get-AccessToken -Settings $s -Scope 'a'
            $null = Get-AccessToken -Settings $s -Scope 'b'
            $global:FakeNow = $global:FakeNow.AddMinutes(56)
            $null = Get-AccessToken -Settings $s -Scope 'a'
        }
        Should -Invoke -ModuleName D365TenantAppUpdater Invoke-WebRequest -Times 3 -Exactly
    }
}

Describe 'HTTP' {
    BeforeEach { Reset-TestModuleState }

    It 'retries 429 and honours Retry-After' {
        $global:Attempts = 0
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest {
            $global:Attempts++
            if ($global:Attempts -lt 3) { return [pscustomobject]@{ StatusCode = 429; Content = ''; Headers = @{ 'Retry-After' = @('7') } } }
            return [pscustomobject]@{ StatusCode = 200; Content = '{"ok":true}'; Headers = @{} }
        }
        InModuleScope D365TenantAppUpdater {
            $global:Slept = @()
            $script:HttpSleep = { param([int] $Seconds) $global:Slept += $Seconds }
            $r = Invoke-Http -Uri 'https://x'
            $r.Status | Should -Be 200
            $r.Json.ok | Should -BeTrue
            $global:Slept | Should -Be @(7, 7)
        }
    }

    It 'never retries a POST (an install or apply is never sent twice)' {
        $global:Attempts = 0
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { $global:Attempts++; [pscustomobject]@{ StatusCode = 503; Content = ''; Headers = @{} } }
        InModuleScope D365TenantAppUpdater {
            $r = Invoke-Http -Method 'POST' -Uri 'https://x' -Body '{}'
            $r.Status | Should -Be 503
        }
        $global:Attempts | Should -Be 1
    }

    It 'never throws on a transport failure' {
        Mock -ModuleName D365TenantAppUpdater Invoke-WebRequest { throw 'No such host is known.' }
        InModuleScope D365TenantAppUpdater {
            $r = Invoke-Http -Uri 'https://x'
            $r.Transport | Should -BeTrue
            Format-RestFailure $r | Should -Match 'transport failure. No such host'
        }
    }
}
