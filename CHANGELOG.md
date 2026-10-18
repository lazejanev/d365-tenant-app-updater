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

## [2.4.3] - 2026-10-18

### Fixed

- **Multi-version `finopsversions` responses were read as "no versions listed".** When the route returned a bare JSON array with two or more entries, `ConvertTo-FinOpsVersionList` probed `$Json.value` (and similar) on the array. PowerShell member enumeration returns one `$null` per entry, which is truthy for two or more entries, so the real list was replaced by `$null`s. Environments offered several versions were never updated. Single-entry responses and responses wrapped in `{"value": [...]}` were unaffected. The parser now only unwraps an object, never an array.
- **F&O detection depended on package order.** `Get-FinOpsMarkerPackage` returned the first installed package whose display name contained "finance and operations". If another such app (for example a virtual entity solution) was listed before the provisioning app, the wrong package was used: its version became the "anchor" (train unknown, so a valid PQU was skipped), and the real provisioning app was sent to the Phase 1 install loop. Unique-name markers are now checked across all packages first, and the display-name fallback ignores virtual entity, dual-write and package manager apps.
- **An F&O environment whose Dataverse read failed vanished from the inventory.** Detection now happens before the Dataverse read. Such an environment is inventoried and never has a version applied in that run (new counter "skipped (Dataverse read)").

### Changed

- **Never-older guard, in every scope.** The Anchor Solution lags the live build but never leads it, so its full version is a lower bound on what is running. A version at or below it is never applied, whether chosen automatically or set in `finOpsTargetVersion`, including with `Any`. Previously the script relied on the apply endpoint to refuse an older version, which was never verified. New counter "skipped (not newer)". The guard is inactive when the Anchor version is not in the `10.0.<train>.<patch>` shape.
- **`VersionUpdate` is bounded.** It now selects only the **next** release train (current + 1) and only versions staged `GeneralAvailability` or `QualityUpdate`. In 2.4.2 it accepted any higher train and any stage, so one run could jump several trains or apply a preview build, including on `UnifiedProduction`. A deliberate multi-train move now needs `Any` plus an explicit `finOpsTargetVersion`.
- Power Platform and BAP tokens are refreshed once they are 45 minutes old, so long runs stay inside token lifetime within the 180-minute job timeout.
- The Dataverse managed-solution query no longer uses `$top`, which suppressed `@odata.nextLink` paging.
- An app install accepted without an operation id now counts in "Update operations triggered".
- The `VersionUpdate` skip line now reads "no version update (next train) available for 10.0.xx".

### Documentation

- README, `docs/parameters.md`, `docs/setup.md`, `CONTRIBUTING.md` and the pipeline header describe the never-older guard and the bounded `VersionUpdate`. The 2.4.2 statement that "the apply endpoint never downgrades" is replaced: that behaviour has not been verified, so the script no longer relies on it.
- CONTRIBUTING invariant 6 now says the Anchor Solution may only narrow an apply, never widen it. Invariant 7 adds bounding and "do not rely on unverified platform refusals". New traps: member enumeration on arrays, `$top` with paging.

## [2.4.2] - 2026-10-06

> **Superseded by 2.4.3.** `VersionUpdate` could jump several trains or pick a non-released build, and multi-version responses could be read as "no versions listed".

### Fixed

- **CRITICAL: `finOpsUpdateScope = QualityUpdate` could move environments to a new release train.** Confirmed live: ten Unified environments on 10.0.48 were updated to 10.0.49.3 in a scheduled run, because `finopsversions` offered 10.0.49.3 staged `QualityUpdate`. `releaseStage` describes the build itself (a quality update on the 10.0.49 train), not its relationship to the environment's current train. v2.4.0 and v2.4.1 wrongly treated it as the latter.
- `QualityUpdate` now requires **both** `releaseStage = QualityUpdate` **and** the same release train (3rd version segment) as the environment.
- `VersionUpdate` now means a **higher** release train than the environment's current one, whatever the `releaseStage`.
- `Any` is unchanged.

### Changed

- The environment's current release train is read from the 3rd segment of the F&O Provisioning App Anchor Solution version. Only the train is used; the patch digit is known to lag and is never used.
- **Fail-safe:** if the current train cannot be determined, the apply is skipped unless the scope is `Any`. New summary counter: "skipped (train unknown)".
- Log messages now name the train, for example "no PQU version available for 10.0.48", and each environment's diagnostic detail shows "Current train".

### Known limitations

- The Anchor Solution is not updated by every update path. If an environment has moved to a new train while its Anchor Solution still shows the old one, `QualityUpdate` skips that environment (it can miss a patch, it never jumps a train), and `VersionUpdate` may treat a same-train patch as a version update.

## [2.4.1] - 2026-09-27

> **Affected by the release-train bug fixed in 2.4.2.** Do not run with `finOpsApplyVersion = true`.

### Changed

- **Wording only, no logic change.** Finance and Operations scope-related messages now use Microsoft's public terminology: "PQU" instead of `QualityUpdate`, and "version update" instead of `VersionUpdate`, via a small `Get-FinOpsScopeLabel` helper. Every `[stage]` bracket in a headline is now `[Status: stage]`, and the diagnostic line listing available versions is labeled "New version available".

## [2.4.0] - 2026-09-27

> **Affected by the release-train bug fixed in 2.4.2.** The scope rule below was incomplete: `releaseStage` alone does not tell you whether a version is on the environment's current train.

### Changed

- Removed patch-level classification based on the F&O Provisioning App Anchor Solution. Multiple environments sharing the identical live application build showed different Anchor Solution patch digits in the same run, because the Dataverse record is not updated by Microsoft's automated Unified environment service update rollout.
- Replaced it with Microsoft's `releaseStage` field from `finopsversions`. `QualityUpdate` selected versions staged `QualityUpdate`; `VersionUpdate` selected versions staged anything else; `Any` ignored the stage. **This was wrong for `QualityUpdate`** - see 2.4.2.
- Rewrote Finance and Operations log output: explanation printed once, one compact headline per environment (also the collapsible group's label).
- The Anchor Solution figure is shown only as a labeled diagnostic value under `dumpDiagnostics`.

## [2.3.9] - 2026-09-27

### Fixed

- Two environments in the same run were reported with different "installed" versions while their live `applicationVersion` was identical. The messages had used the Anchor Solution's Dataverse reading as "installed". Superseded by 2.4.0.

## [2.3.8] - 2026-09-26

### Changed

- Restored per-environment collapsible `##[group]` blocks for Finance and Operations detail, with the group's **label set to the full headline**, so Azure DevOps shows the outcome even when the group is collapsed.

## [2.3.7] - 2026-09-26

### Changed

- (Superseded by 2.3.8) Removed collapsible groups entirely.

## [2.3.6] - 2026-09-25

### Changed

- One headline sentence per environment, printed first, covering every outcome branch. Supplementary detail follows, gated by `dumpDiagnostics`.
- The Finance and Operations inventory table is unconditional.

### Added

- `dumpSolutionCatalog` (default `false`), separated from `dumpDiagnostics`.

## [2.3.5] - 2026-09-24

### Fixed

- The F&O Provisioning App Anchor Solution is excluded from Phase 1's generic install loop, so the same version jump is no longer reported as both "manual install required" and "accepted, applying".

## [2.3.4] - 2026-09-23

### Fixed

- A regression where a client-side "already at or above" pre-check (comparing two incompatible version schemes) had been reintroduced. The apply call's own response (202/204) is the only authority.

## [2.3.3] - 2026-09-22

### Added

- `finOpsUpdateScope` (`QualityUpdate` default, `VersionUpdate`, `Any`).

## [2.3.2] - 2026-09-21

### Added

- Admin Mode detection for Phase 1 app installs: detected on the first "not enabled" failure per environment, remaining apps for that environment skipped.

## [2.3.1] - 2026-09-20

### Fixed

- Removed the client-side "already at or above" pre-check before calling apply. The apply call's own response (`202` = applying, `204` = already at or above) is the sole authority.

## [2.3.0] - 2026-09-19

### Added

- `finOpsApplyVersion` as the single Finance and Operations on/off switch. Inventory always runs and is read-only. `finOpsInventory` and `updateFinOpsVersion` are ignored with a one-time warning.

### Removed

- `pollIntervalSec` and `pollTimeoutMin` (never read).

### Changed

- Transport failures are reported as transport failures instead of `HTTP -1`.
- The Finance and Operations phase requires PowerShell 7.

## [2.2.0] - 2026-09-18

### Added

- Finance and Operations inventory and version update against the documented Power Platform routes, gated behind a live route check.

### Changed

- Every environment is probed individually.
- Reporting is factual: the script states what the API returned.
- `finOpsDeploymentTypes` controls eligible deployment types. Default excludes LCS managed environments.

## [2.0.0] - 2026-08-18

### Changed

- Required configuration reduced to `ClientId`, `ClientSecret`, `TenantId`. Every other setting is optional with a built-in default.
- Optional settings are passed through the pipeline `env:` block.

## [1.4.0] - 2026-08-18

### Added

- Real app-update logic: available versions from App Management, installed versions from Dataverse managed solutions, strict never-downgrade comparison, install with operation id, failed-install retry.

## [1.2.0] - 2026-08-18

### Added

- `AppExclude` deny-list, Custom Install Experience detection, optional PAC CLI fallback.

## [1.1.0] - 2026-08-18

### Added

- `EnvironmentExclude` deny-list.

### Changed

- `RetryFailedInstalls` defaults to on.

## [1.0.0] - 2026-08-16

### Added

- Initial public release.
