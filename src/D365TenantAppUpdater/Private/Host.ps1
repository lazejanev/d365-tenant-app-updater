# Host adapter: the only place that knows whether the run is on Azure DevOps,
# GitHub Actions or a local machine. Everything else writes through these
# functions, so both platforms are first-class.

$script:HostKind = $null

function Get-HostKind {
    if ($script:HostKind) { return $script:HostKind }
    if ($env:GITHUB_ACTIONS -eq 'true') { $script:HostKind = 'GitHub' }
    elseif ($env:TF_BUILD -ieq 'true') { $script:HostKind = 'AzureDevOps' }
    else { $script:HostKind = 'Local' }
    return $script:HostKind
}

function Set-HostKind {
    # Tests only.
    param([ValidateSet('GitHub', 'AzureDevOps', 'Local')] [string] $Kind)
    $script:HostKind = $Kind
}

function Write-Line {
    param([AllowEmptyString()] [string] $Text = '')
    Write-Host $Text
}

function Write-Section {
    param([string] $Text)
    Write-Host ''
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##[section]$Text" }
        default       { Write-Host "===== $Text =====" }
    }
}

function Start-Group {
    param([string] $Title)
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##[group]$Title" }
        'GitHub'      { Write-Host "::group::$Title" }
        default       { Write-Host "--- $Title" }
    }
}

function Stop-Group {
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host '##[endgroup]' }
        'GitHub'      { Write-Host '::endgroup::' }
        default       { }
    }
}

function ConvertTo-AnnotationText {
    # Workflow commands end at a newline; keep annotations on one line.
    param([string] $Text)
    return ($Text -replace "`r?`n", ' ')
}

function Write-RunWarning {
    param([string] $Text)
    $t = ConvertTo-AnnotationText $Text
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]$t" }
        'GitHub'      { Write-Host "::warning::$t" }
        default       { Write-Host "WARNING: $t" }
    }
}

function Write-RunError {
    param([string] $Text)
    $t = ConvertTo-AnnotationText $Text
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##vso[task.logissue type=error]$t" }
        'GitHub'      { Write-Host "::error::$t" }
        default       { Write-Host "ERROR: $t" }
    }
}

function Set-RunOutput {
    # A value later stages or jobs can read (has-actions flags).
    param([string] $Name, [string] $Value)
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value" }
        'GitHub'      { if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8 } }
        default       { }
    }
}

function Publish-RunSummary {
    # Shows the markdown summary on the run page.
    param([string] $MarkdownPath)
    if (-not (Test-Path $MarkdownPath)) { return }
    switch (Get-HostKind) {
        'AzureDevOps' { Write-Host "##vso[task.uploadsummary]$((Resolve-Path $MarkdownPath).Path)" }
        'GitHub'      { if ($env:GITHUB_STEP_SUMMARY) { Get-Content -Path $MarkdownPath -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY -Encoding utf8 } }
        default       { }
    }
}

function Complete-Run {
    # Returns the process exit code and tells the host how the run ended.
    #   Succeeded            - nothing went wrong
    #   SucceededWithIssues  - something failed, but the run did its job
    #                          (Azure DevOps shows an orange run; GitHub has no
    #                          such state, so the run stays green with warning
    #                          annotations unless failOnIssues = true)
    #   Failed               - the run could not do its job (sign-in,
    #                          discovery, a broken plan file)
    param([ValidateSet('Succeeded', 'SucceededWithIssues', 'Failed')] [string] $Result, [bool] $FailOnIssues = $false)
    $global:LASTEXITCODE = 0
    switch ($Result) {
        'Succeeded' { return 0 }
        'SucceededWithIssues' {
            if ($FailOnIssues) {
                if ((Get-HostKind) -eq 'AzureDevOps') { Write-Host '##vso[task.complete result=Failed;]Completed with issues and failOnIssues = true. See the run summary.' }
                return 1
            }
            if ((Get-HostKind) -eq 'AzureDevOps') { Write-Host '##vso[task.complete result=SucceededWithIssues;]Completed with issues. See the run summary.' }
            return 0
        }
        'Failed' {
            if ((Get-HostKind) -eq 'AzureDevOps') { Write-Host '##vso[task.complete result=Failed;]The run could not complete. See the log.' }
            return 1
        }
    }
}

function Get-DefaultOutputDirectory {
    switch (Get-HostKind) {
        'AzureDevOps' { if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) { return (Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'd365-tenant-app-updater') } }
        'GitHub'      { if ($env:RUNNER_TEMP) { return (Join-Path $env:RUNNER_TEMP 'd365-tenant-app-updater') } }
    }
    return (Join-Path (Get-Location).Path 'd365-tenant-app-updater-output')
}
