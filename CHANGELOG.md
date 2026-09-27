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

## [2.4.1] - 2026-09-27

### Changed

- **Wording only, no logic change.** Finance and Operations scope-related messages now use Microsoft's own public terminology: "PQU" (proactive quality update) instead of the internal `QualityUpdate` enum value, and "version update" instead of `VersionUpdate`, via a small `Get-FinOpsScopeLabel` helper. Every `[stage]` bracket in a headline is now `[Status: stage]`, and the diagnostic line listing what versions are available is now labeled "New version available" rather than the bare "Available". None of this affects the `releaseStage` matching logic itself, which is unchanged.

## [2.4.0] - 2026-09-27

### Changed

- **REMOVED all classification logic based on the F&O Provisioning App Anchor Solution.** Confirmed live, across ten environments in one pipeline run: every one of them shared the *identical* live application build (`10.0.2645.136`), yet their Anchor Solution readings split into two different, disagreeing values (`10.0.48.6` and `10.0.48.7`). This is not a timing lag - the Anchor Solution's version in Dataverse is only set by a Dataverse-level solution operation (an environment copy from an already-updated source, or an explicit solution import), and is **not** updated by Microsoft's own automated Unified environment service update rollout, which is how these environments are actually updated in normal operation. The Anchor Solution was therefore never a safe basis for deciding what kind of update is available, and no longer is used for that purpose anywhere in this script.
- **Replaced it with Microsoft's own `releaseStage` field**, present on every entry returned by `finopsversions` (confirmed in a raw captured response: `{"version":"10.0.48.7","releaseStage":"QualityUpdate"}` alongside a second entry staged `GeneralAvailability`). `finOpsUpdateScope` now matches directly against this field: `QualityUpdate` selects only versions staged `QualityUpdate`; `VersionUpdate` selects only versions staged anything else; `Any` ignores the stage entirely.
- **Rewrote all Finance and Operations log output to be dramatically shorter.** The previous format repeated the same explanatory sentence in full on every single environment line, making 13 environments unreadable at a glance. Explanatory text now appears once, in a short legend printed at the start of the section. Per-environment output is one compact headline (also the collapsible group's label, so it is visible even collapsed).
- The Anchor Solution figure is still shown, but only as a single, clearly-labeled, non-decisive diagnostic value under `dumpDiagnostics` - never in a headline, and never used to accept, reject, or classify anything.

## [2.3.9] - 2026-09-27

### Fixed

- A real bug, confirmed live: two environments (in the same run) were reported with different "installed" versions, suggesting they were on different releases. A direct side-by-side check against the live API showed both environments return the *identical* `applicationVersion` - they were never on different versions. The messages had been sourcing "installed X" from the Anchor Solution's Dataverse-catalog reading rather than the live application build, and after a real apply completed on one environment, its live version updated immediately while the Dataverse record lagged.
- Superseded one release later by v2.4.0 above, once it became clear the lag was not occasional but structural for environments updated via Microsoft's own automated rollout.

## [2.3.8] - 2026-09-26

### Changed

- Restored per-environment collapsible `##[group]` blocks for Finance and Operations detail (a v2.3.7 change had removed them), but set the group's **label to the full headline** rather than a generic placeholder, so Azure DevOps shows the actual outcome even when the group is collapsed - its default state. This means every environment's result is directly comparable at a glance without expanding any of them.

## [2.3.7] - 2026-09-26

### Changed

- (Superseded by v2.3.8) Removed collapsible groups entirely in response to two environments with an identical outcome appearing to differ, because Azure DevOps' viewer had independently expanded one and collapsed the other, and the collapsed label at the time was a generic, uninformative placeholder rather than the outcome itself.

## [2.3.6] - 2026-09-25

### Changed

- Reorganised all Finance and Operations output: exactly one headline sentence per environment, printed first, covering every outcome branch (success, every skip reason, every failure reason). Supplementary detail follows, gated by `dumpDiagnostics`.
- The Finance and Operations inventory table is now unconditional, matching the feature's own stated design (inventory always runs, read-only).

### Added

- `dumpSolutionCatalog` (default `false`), separated out from `dumpDiagnostics`. The latter previously also triggered a dump of every Dataverse managed solution matching a broad generic hint list, which on a Sales-heavy environment produced 150+ lines unrelated to Finance and Operations.

## [2.3.5] - 2026-09-24

### Fixed

- The F&O Provisioning App Anchor Solution is now excluded from Phase 1's generic install loop entirely. It was always rejected there with a Custom Install Experience response, and is exclusively owned by Phase 2's dedicated route - attempting it in both places produced contradictory output: the identical version jump reported simultaneously as "manual install required" (Phase 1's failed generic attempt) and "accepted, applying" (Phase 2's correct dedicated apply).

## [2.3.4] - 2026-09-23

### Fixed

- A regression where a client-side "already at or above" pre-check (comparing two mutually incompatible version numbering schemes) had been accidentally reintroduced during a rebuild. There is no client-side check of this kind anywhere in the apply path; the apply call's own response (202/204) is the only authority used, as originally intended by v2.3.1.

## [2.3.3] - 2026-09-22

### Added

- `finOpsUpdateScope` (`QualityUpdate` default, `VersionUpdate`, `Any`). `finopsversions` returns entries in the F&O named-release scheme (e.g. `10.0.48.7`), a different scheme from `finopsproperties.applicationVersion` (build-scale, e.g. `10.0.2645.136`). At this point in the project's history, the F&O Provisioning App Anchor Solution (read in Phase 1 from Dataverse managed solutions) was used as the "from" reference for classification, since it shared the release scheme; this was later found to be unreliable and replaced in v2.4.0.

## [2.3.2] - 2026-09-21

### Added

- Admin Mode detection for Phase 1 app installs. An environment left in Administration Mode rejects every install with an identical "not enabled" message; this is now detected on the first such failure per environment, logged once, and every remaining app in that environment is skipped without a further attempt.

## [2.3.1] - 2026-09-20

### Fixed

- Removed the client-side "already at or above" pre-check before calling apply, which used to compare `finopsproperties.applicationVersion` (build-scale) directly against `finopsversions` entries (release scheme) and produced false "already up to date" results. Replaced with trusting the apply call's own response (`202` = applying, `204` = already at or above) as the sole authority.

## [2.3.0] - 2026-09-19

### Added

- `finOpsApplyVersion` as the single Finance and Operations on/off switch. Inventory always runs and is read-only. If a variable named `finOpsInventory` or `updateFinOpsVersion` is present in the environment, it is ignored and the script says so once in the log.

### Removed

- `pollIntervalSec` and `pollTimeoutMin`. Both were resolved into config and never read; no polling loop existed.

### Changed

- Transport failures are now reported as transport failures instead of being rendered as `HTTP -1`.
- The Finance and Operations phase requires PowerShell 7 and is skipped with a clear message on Windows PowerShell 5.1.

## [2.2.0] - 2026-09-18

### Added

- Finance and Operations inventory and version update, implemented against the documented Power Platform routes, gated behind a live route check so it activates automatically when the route becomes available on an endpoint.

### Changed

- Every environment is probed individually rather than short-circuiting after the first failure.
- Reporting is factual: the script states what the API returned rather than asserting a cause.
- `finOpsDeploymentTypes` controls which deployment types are eligible for a version apply. Default excludes LCS managed environments.

## [2.0.0] - 2026-08-18

### Changed

- Reduced the required variable group to three values: `ClientId`, `ClientSecret`, `TenantId`.
- Every other setting became optional with a built-in default, overridable by adding a variable with the matching name.
- Optional settings are passed through the pipeline `env:` block so an undefined variable stays a harmless literal and the script falls back to its default.

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
