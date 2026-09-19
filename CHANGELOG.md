# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Planned

- Install completion polling against the operation status route, once that route is confirmed against a live endpoint.
- Per-environment approval gates before install.
- Teams or email summary notification after each run.
- Parallel installs across environments.
- Dry-run report published as a pipeline artifact.

## [2.3.0] - 2026-09-19

### Added

- **`finOpsApplyVersion`** is the single Finance and Operations variable. Inventory always runs and is read-only; there is no switch for it. Version apply is off by default and this is the only variable that can turn it on.
- A runtime parameter for `finOpsApplyVersion`, so it can be flipped for a single manual run.
- An explicit warning block in the log whenever version apply is enabled, stating that eligible environments will be moved to a new application version.
- A PowerShell version guard. The Finance and Operations phase requires PowerShell 7 because it uses `-SkipHttpErrorCheck`. On Windows PowerShell 5.1 the phase is now skipped with a clear message instead of failing obscurely inside `Invoke-WebRequest`. Phase 1 is unaffected.
- Independent confirmation of the version-route gap via Microsoft's own `pac dynamics` CLI (`get-fin-ops-versions`, `apply-fin-ops-version`), which construct and issue the identical request URL as the script's raw REST calls and receive the identical `RouteNotFound` response. Documented in the README and setup guide as a second, independent method of reproduction.

### Changed

- **Version apply can no longer be enabled by more than one variable.** Two earlier designs were considered and rejected during this release: a single combined switch (the original `updateFinOpsVersion`, which enabled both inventory and apply together), and a two-switch design (`finOpsInventory` + `finOpsApplyVersion`). Both were replaced with one variable, because apply is gated behind a live route check and would otherwise begin running automatically once `finopsversions` became available on an endpoint — under either of the earlier designs, a variable group that had merely enabled the F&O phase for the inventory table could have started applying application versions on its next scheduled run with no configuration change. With `finOpsApplyVersion` as the sole trigger, that path does not exist: apply only ever runs when this one variable is explicitly `true`.
- **Transport failures are reported as transport failures.** A request that never produced an HTTP response (DNS, TLS, proxy, timeout, unsupported parameter) was previously rendered as `HTTP -1`. It now says that no HTTP response was received, and includes the underlying detail.
- The `sync-from-github.yml` schedule comment now matches its cron. The schedule is weekly on Mondays at 06:00 UTC; the inline comment and the README both previously claimed hourly.
- The `azure-pipelines.yml` header no longer states that a 404 means the environment is not a PPAC-managed F&O environment. That was an early hypothesis that diagnostics disproved, and it contradicted the project's own rule of reporting what the API returned rather than asserting a cause. The header now records the verified observation instead, including the `apply` sub-route and the CLI-based reproduction.
- `docs/permissions.md` no longer instructs the reader to add an unnamed "matching" API permission. It states what was actually verified: the management application registration was sufficient on its own, with guidance on what to do if a tenant is configured more restrictively.
- `docs/parameters.md` and the README now warn that `appExclude` falls back to substring matching when the value contains no `*`, and that a short value matches far more broadly than intended.
- `CONTRIBUTING.md` now documents the project's non-negotiable invariants, including a rule specific to this release: exactly one variable may ever enable a destructive Finance and Operations capability, and a retired variable name is never repurposed to mean something else.
- The variable group table in `docs/setup.md` renders as a table again.

### Removed

- **`pollIntervalSec` and `pollTimeoutMin`.** Both were resolved into config and never read; no polling loop existed, yet the README and `docs/parameters.md` described them as real behaviour. Rather than keep documented settings that did nothing, they are gone. Install operations are still triggered and their operation id reported. Completion polling is on the roadmap and will return once the operation status route is confirmed against a live endpoint.

### Retired

- **`finOpsInventory`** and **`updateFinOpsVersion`.** Neither exists as a script parameter any more. If either is still present as an environment variable when the script runs, it is ignored entirely and a one-time warning names exactly which one was found. Inventory always runs regardless, and `finOpsApplyVersion` is the only variable that governs apply. See `docs/parameters.md` for the full history.

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
