# Release Notes

## v1.3.0 - 2026-08-18

### Added

- **Automatic Power Platform CLI install** - a conditional pipeline step that runs only when the PAC fallback is enabled. It installs the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent, so you no longer need to pre-install the CLI yourself.
- **`pacCliVersion` variable** - pin the Power Platform CLI version for reproducible runs (default `2.11.2`), or leave it blank to install the latest.
- **.NET 10 guidance** - documented that recent CLI tool versions (2.11.x) target .NET 10.0, along with the correct `.Tool` package name.

### Notes

- The install step only runs when `usePacFallback` is on, so normal runs are unaffected.
- On self-hosted agents, ensure a compatible .NET SDK (10.x) is present, or pin an older `pacCliVersion`.

---

## v1.2.0 - 2026-08-18

### Added

- **`AppExclude` deny-list** - a list of application names or ids that are always skipped on every environment. Pre-seeded with `msdyn_FinanceAndOperationsProvisioningApp` (the Finance and Operations Provisioning App / Anchor Solution), so custom-install apps are skipped out of the box.
- **Smart Custom Install Experience detection** - the script recognizes the API's 400 response ("This application utilizes a Custom Install Experience... not supported by this API"). Such apps are classified as `manual-required` instead of `failed`, so retry no longer hammers them on every run, and they are listed in a dedicated "Manual install required (use PPAC)" summary block.
- **Optional PAC CLI fallback (`UsePacFallback`, off by default)** - when enabled, apps rejected by the API for a custom install are retried with `pac application install`, authenticated via the same service principal. Best effort: the CLI calls the same programmability API family, so true Single Page Application install apps may still be blocked, in which case the app falls back to `manual-required`.
- **Expanded run summary** - now reports counts for updated, skipped-excluded, manual-required, and failed apps.

### Notes

- Community project, not an official Microsoft tool. Test against a non-production tenant first.
- The PAC CLI fallback requires the pac CLI to be present on the agent; from v1.3.0 the pipeline installs it automatically when the fallback is enabled.

---

## v1.1.0 - 2026-08-18

### Added

- **`EnvironmentExclude` deny-list** to always skip specific environments (for example Production), even when they match the filter.
- Worked examples in the docs showing how the allow-list and deny-list combine.

### Changed

- `RetryFailedInstalls` now defaults to on.
- The effective settings block in the log now echoes both the filter and the exclude list.

---

## v1.0.0 - 2026-08-16

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
