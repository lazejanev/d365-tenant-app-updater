# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Planned
- Per-environment approval gates before install.
- Teams or email summary notification after each run.
- Parallel installs across environments.
- Dry-run report published as a pipeline artifact.

## [2.0.0] - 2026-08-18

### Changed (breaking to the configuration model, not the behavior)
- Reduced the required variable group to just three values: `ClientId`, `ClientSecret`, `TenantId`.
- Every other setting is now optional with a built-in default in the script. Override any default by adding a variable with the matching name to the group; no YAML edits required.
- Optional settings are passed through the pipeline `env:` block so an undefined variable stays a harmless literal and the script falls back to its default (this removes the earlier "unresolved `$(...)` argument" failure class).
- Removed the `pipelineName`, `agentVmImage`, and `jobTimeoutMinutes` variables; these are now fixed in the YAML.
- Removed the endpoint/API variables from the required set; they are now optional overrides (`bapApiRoot`, `bapApiVersion`, `powerPlatformScope`, `ppApiRoot`, `appManagementApiVersion`, `pollIntervalSec`, `pollTimeoutMin`, `authority`).
- `bapApiVersion` default updated to `2026-06-01`.
- `whatIf` and `usePacFallback` exposed as queue-time runtime parameters in addition to being overridable variables.

### Added
- Comprehensive README with goal, how-it-works diagram, requirements, and the required/optional variable model.
- Updated setup, permissions, and parameters docs to match the new model.

## [1.4.0] - 2026-08-18

### Added
- Wired the real app-update logic: available versions from the Power Platform App Management API, installed versions from Dataverse managed solutions, strict version comparison (never downgrade), install with operation id, and failed-install retry.
- App Management endpoint configuration (`ppApiRoot`, `appManagementApiVersion`).

## [1.3.0] - 2026-08-18

### Added
- Conditional "Install Power Platform CLI" step that runs only when the PAC fallback is enabled, installing the `Microsoft.PowerApps.CLI.Tool` .NET tool.
- `pacCliVersion` support and .NET 10 guidance.

## [1.2.0] - 2026-08-18

### Added
- `AppExclude` deny-list (pre-seeded with `msdyn_FinanceAndOperationsProvisioningApp`).
- Smart detection of the "Custom Install Experience" 400; such apps are reported as `manual-required` instead of `failed`.
- Optional PAC CLI fallback (`UsePacFallback`, off by default).

## [1.1.0] - 2026-08-18

### Added
- `EnvironmentExclude` deny-list to always skip specific environments.

### Changed
- `RetryFailedInstalls` defaults to on.

## [1.0.0] - 2026-08-16

### Added
- Initial public release: service principal auth, environment discovery, version comparison, install, retry, diagnostics, and docs.
