# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Planned
- Per-environment approval gates before install.
- Teams or email summary notification after each run.
- Parallel installs across environments.
- Dry-run report published as a pipeline artifact.

## [2.2.0] - 2026-09-19

### Added
- **Finance and Operations inventory.** For every environment where F&O is installed, the pipeline reports application version, platform version, deployment type, AOS counts (interactive and batch), demo dataset and scheduled actions, then prints a consolidated table that makes version drift across the tenant obvious.
- **Finance and Operations version update** implemented against the documented Power Platform routes (`finopsversions` and `finopsversions/{version}/apply`), gated behind a live route check so it activates automatically when the route becomes available on an endpoint.
- New variables: `updateFinOpsVersion`, `finOpsTargetVersion`, `finOpsEnvironmentFilter`, `finOpsDeploymentTypes`, `finOpsApiVersion`.
- New runtime parameters for `updateFinOpsVersion` and `finOpsTargetVersion`.
- F&O detection during Phase 1 at no extra API cost, based on installed application packages.

### Changed
- **LCS managed environments are inventoried but never version-updated.** `finOpsDeploymentTypes` defaults to `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction`, because LCS environments are updated through Lifecycle Services rather than the Power Platform API.
- **Every environment is probed individually.** An earlier build stopped after the first `RouteNotFound` and assumed the remaining environments would behave the same way, which hid potential differences between deployment types.
- **Reporting is factual.** The log states what the API returned, for example `RouteNotFound`, instead of asserting a cause.
- The Finance and Operations phase calls the REST API directly and no longer requires the Power Platform CLI. The CLI is installed only when the optional app-install fallback is enabled.
- `appExclude` now defaults to empty. Apps that require the Power Platform Admin Center wizard are reported under "manual install required" rather than being hidden.
- `appExclude` matching supports exact, wildcard and substring forms.

### Fixed
- **Error classification.** PowerShell places the HTTP response body in `$_.ErrorDetails.Message`, not `$_.Exception.Message`. Reading only the latter caused "Custom Install Experience" responses to be counted as failures instead of manual install required.
- **Variable collision.** PowerShell variable names are case-insensitive, so a local sharing a name with a `[string]` parameter was coerced to a string and evaluated as truthy, which could skip the entire application phase. All locals are now prefixed.
- `$LASTEXITCODE` is reset after every external call and the script exits explicitly, so a non-zero code left by an external tool cannot fail the task.
- The Finance and Operations phase is wrapped so it can never fail the build.

## [2.0.0] - 2026-08-18

### Changed
- Reduced the required variable group to three values: `ClientId`, `ClientSecret`, `TenantId`.
- Every other setting became optional with a built-in default, overridable by adding a variable with the matching name.
- Optional settings are passed through the pipeline `env:` block so an undefined variable stays a harmless literal and the script falls back to its default.
- Removed the `pipelineName`, `agentVmImage` and `jobTimeoutMinutes` variables; these are fixed in the YAML.
- `bapApiVersion` default updated to `2026-06-01`.

## [1.4.0] - 2026-08-18

### Added
- Wired the real app-update logic: available versions from the Power Platform App Management API, installed versions from Dataverse managed solutions, strict never-downgrade comparison, install with operation id, and failed-install retry.

## [1.2.0] - 2026-08-18

### Added
- `AppExclude` deny-list.
- Detection of the "Custom Install Experience" response; such apps are reported as manual install required rather than failures.
- Optional PAC CLI fallback, off by default.

## [1.1.0] - 2026-08-18

### Added
- `EnvironmentExclude` deny-list to always skip specific environments.

### Changed
- `RetryFailedInstalls` defaults to on.

## [1.0.0] - 2026-08-16

### Added
- Initial public release: service principal auth, environment discovery, version comparison, install, retry, diagnostics, and docs.
