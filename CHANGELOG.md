# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Planned
- Per-environment approval gates before install.
- Teams or email summary notification after each run.
- Parallel installs across environments.
- Dry-run report published as a pipeline artifact.

## [1.3.0] - 2026-08-18

### Added
- Conditional "Install Power Platform CLI" pipeline step that runs only when the PAC fallback is enabled, installing the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent.
- `pacCliVersion` variable to pin the Power Platform CLI version (default `2.11.2`), or leave blank to install the latest.
- Documentation of the .NET 10 requirement for recent CLI tool versions and the correct `.Tool` package name.

## [1.2.0] - 2026-08-18

### Added
- `AppExclude` deny-list of application names/ids that are always skipped on every environment. Pre-seeded with `msdyn_FinanceAndOperationsProvisioningApp`.
- Smart detection of the "Custom Install Experience" 400. Such apps are classified as `manual-required` instead of `failed`, so retry no longer hammers them, and they appear in a dedicated "Manual install required (PPAC)" summary.
- Optional PAC CLI fallback (`UsePacFallback`, off by default) that attempts `pac application install` for custom-install apps. Best effort; the CLI may still be blocked for true SPA-install apps.
- Summary now reports updated, skipped-excluded, manual-required, and failed counts.

## [1.1.0] - 2026-08-18

### Added
- `EnvironmentExclude` deny-list to always skip specific environments (for example Production), even when they match the filter.
- Worked examples in the docs showing how the allow-list and deny-list combine.

### Changed
- `RetryFailedInstalls` now defaults to on.
- Effective settings block in the log now echoes both the filter and the exclude list.

## [1.0.0] - 2026-08-16

### Added
- Initial public release.
- Service principal authentication for Power Platform and BAP admin APIs (client credentials).
- Tenant-wide environment discovery through the admin environments endpoint.
- Installed versus available version comparison per app, per environment.
- Automatic install of required updates with completion polling.
- Optional retry of previously failed installs (`RetryFailedInstalls`).
- Diagnostic dump of installed versus available versions (`DumpDiagnostics`).
- `WhatIf` plan-only mode.
- `EnvironmentFilter` to scope a run to specific environments.
- Documentation: setup, permissions, and parameters guides.
