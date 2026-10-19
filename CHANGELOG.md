# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to Semantic Versioning.

## [Unreleased]

### Planned

- Teams or email summary notification after each run.
- Parallel installs across environments.
- Remove partial (substring) `appExclude` matching (deprecated in 3.0.0).

## [3.0.0] - 2026-10-18

### Highlights

**Production waits for proof. GitHub joins Azure DevOps. No secret needed.**

v3 keeps every v2 setting, so your variable group keeps working, and adds the controls a tenant-wide updater needs before it touches production.

- **Production ring (on by default).** Non-production environments update as soon as a version is available ("test and break fast"). A production environment only takes a version that a non-production environment already runs. Applies to Dynamics 365 apps and to Finance and Operations. Everything held back is listed with the reason. `productionRing = false` restores v2 behaviour.
- **Plan, then apply.** The pipeline now has three stages: Plan (reads the tenant, changes nothing), Apply non-production, Apply production. Optionally require an approval before production (Azure DevOps: `productionApprovalEnvironment`; GitHub: the `d365-production` environment) if you want a person to sign off production. Apply re-checks every action against the live tenant first.
- **GitHub Actions.** The same module, rules and three jobs run on GitHub. See `docs/setup-github.md`.
- **No client secret.** Sign in with OpenID Connect on GitHub, or workload identity federation on Azure DevOps (preview). The secret remains supported, and works as a backup.
- **You see the outcome.** Every run publishes a summary on the run page and a JSON report. App installs are triggered and the next run reports them; optionally the run waits and reports each install itself.
- **A to Z.** Environments and apps are processed and reported in alphabetical order, with numbers in numeric order (Dev2 before Dev10), identical on every agent.
- **A clearer results view.** The log ends with a colour-coded board, one line per app grouped by environment; the run page opens with counters and the same list.
- **Architecture diagrams.** `docs/architecture.md` shows how it all fits together.
- **Tested.** 141 automated tests run on every change, on Linux and Windows, with no tenant needed.

**Upgrading:** PowerShell 7.2+ is now required for the whole run (Microsoft-hosted agents have it). Copy `src/` and `pipelines/` along with `scripts/`, and replace `azure-pipelines.yml`. Full guide: `docs/upgrading-to-v3.md`.

Major version: production is held back by default, and the run is split into Plan and Apply. Every v2 setting keeps its name and meaning, so existing variable groups keep working. See [docs/upgrading-to-v3.md](docs/upgrading-to-v3.md).

### Added

- **Production ring, on by default** (`productionRing`). A production environment only takes a version that a non-production environment in scope already runs: apps by installed solution version, F&O by live release train and offered list. Production is PPAC type Production (`productionEnvironmentTypes`), environments named in `productionEnvironments`, and F&O deployment types `UnifiedProduction` / `LCSProduction`. Optional `productionSoakDays` for apps. Held items are listed with the reason.
- **Plan and Apply.** `-Mode Plan` writes `plan.json` and changes nothing; `-Mode Apply -Ring NonProduction|Production` applies a plan after re-checking every action against the live tenant and the current settings (`Stale`, `AlreadyDone` and `Stopped` are reported, never improvised). `-Mode PlanAndApply` (default) keeps the v2 single-run behaviour.
- **Azure DevOps pipeline with three stages**: Plan, Apply non-production, Apply production. Production approval is opt-in: `productionApprovalEnvironment` (default `none`) names an Azure DevOps environment you created with an Approvals check, and the production stage then deploys to it. Shared templates in `pipelines/templates/`.
  - Fixed before release: the production stage referenced the environment `d365-production` by default. Azure DevOps does not create environments for YAML that arrives through a git sync, so every run failed at queue time with "Environment d365-production could not be found".
- **GitHub Actions support**: `.github/workflows/tenant-app-updater.yml` with the same three jobs, OpenID Connect sign-in, and the `d365-production` environment for optional required reviewers. Setup: [docs/setup-github.md](docs/setup-github.md).
- **Federated sign-in, no secret**: GitHub OIDC, and Azure DevOps workload identity federation through `azure-pipelines-federated.yml` (preview). `authMode` (`Auto`, `Federated`, `ClientSecret`): in `Auto` a refused federated sign-in falls back to the client secret with a warning.
- **Optional wait for app installs** (`waitForInstallsMinutes`, default `0` = trigger and move on, as in v2). With a number of minutes the Apply stage waits, prints a progress line every minute, and reports each install as Succeeded, Failed or TimedOut.
- **Progress while reading the tenant**: the Plan stage prints one line per environment as it reads it (`3/17  commerce-code-ppr  59 installed apps, 1776 solutions, F&O (6s)`) and one per F&O environment, so a long read never looks stuck.
- **Run summary on the run page** (Azure DevOps Extensions tab, GitHub job summary) and `report.json`, published as artifacts with `plan.json`.
- **A to Z everywhere**: environments and apps are processed and listed alphabetically: case-insensitive, numbers in numeric order (Dev2 before Dev10), `-`, `_`, `.` and spaces treated alike, and the same order on every agent and locale (ordinal comparison, not culture rules). Non-production is applied before production.
- **Results board**: the log ends with every environment A to Z and one colour-coded, tagged line per app (`[UPDATED]`, `[RUNNING]`, `[PLANNED]`, `[HELD]`, `[FAILED]`, ...), coloured with Azure DevOps formatting, ANSI on GitHub, and console colours locally. Production lines say which non-production environment proved the version.
- **Run summary redesign**: counters first, then one A to Z list with a status icon per row, Needs attention, environments, and F&O. Each stage has a named section (1. Plan, 2. Apply non-production, 3. Apply production); the inventory is shown once, in Plan. Number columns are centred and F&O says yes or no.
- **Architecture diagrams**: [docs/architecture.md](docs/architecture.md) with seven diagrams (system context, pipeline stages, production ring, module, app decision, F&O decision, sign-in), Mermaid sources in `docs/diagrams/`, and screenshots of the log and run summary.
- F&O inventory shows each environment's **maintenance window** (`finopsadminsettings`).
- `failOnIssues`: fail the run (exit code 1) instead of finishing with issues.
- **Tests and CI**: Pester suite (141 tests, including the 22 F&O scenarios that verified 2.4.3 and 2.4.4) on Linux and Windows, PSScriptAnalyzer and a YAML check on every pull request; `release.yml` publishes a GitHub release from a version tag.

### Changed

- The 1,456-line script is now the `D365TenantAppUpdater` module (`src/`); `scripts/Update-TenantApps.ps1` is a thin entry point with the same parameters. `ModuleVersion` in the manifest is the single source of the version.
- **Repository layout.** The root keeps only what a platform requires there: `azure-pipelines.yml` and `sync-from-github.yml` (existing Azure DevOps pipelines point at these paths) and `.github/workflows/`. Everything else for Azure DevOps lives in `pipelines/` (`azure-pipelines-federated.yml`, and two templates: `stages.yml`, `run-updater.yml`). The module is one flat folder, `src/D365TenantAppUpdater/`. `RELEASE_NOTES.md` is merged into this file (the Highlights above); the analyzer settings moved to `.github/`.
- **PowerShell 7.2 or later is required** for the whole run (v2 ran the apps phase on 5.1).
- Tokens are cached per API and renewed five minutes before they expire (v2: refreshed after 45 minutes).
- 429 and 503 responses are retried (up to three attempts, honouring `Retry-After`).
- A run where something could not be read or an install failed ends as SucceededWithIssues (orange on Azure DevOps) instead of green.
- Safety switches (`productionRing`, `whatIf`, `finOpsApplyVersion`) keep their safe value, with a warning, when set to something that is not true or false. An environment whose type is not reported is treated as production.
- Only GET requests are retried on 429/503; an install or apply POST is never sent twice.
- `sync-from-github.yml` syncs the latest GitHub release by default (`syncRef = main` for the previous behaviour).

### Deprecated

- `appExclude` values that only match part of an app name. They still work and are reported once per run with the wildcard to use instead.

### Unchanged

- All Finance and Operations rules from 2.4.4: inventory always, apply only with `finOpsApplyVersion = true`, release train from the live build through Microsoft's PQU schedule, never a lower train, never the Anchor Solution.

## [2.4.4] - 2026-10-18

### Changed

- **The build-to-release map is built automatically on every run.** At the start of the Finance and Operations phase the script downloads Microsoft's [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule) from its public source on GitHub (`MicrosoftDocs/Dynamics-365-Unified-Operations-public`) and reads every row shaped like `10.0.49 PQU-1 ... 10.0.2790.83`. When Microsoft publishes a new release, the next run picks it up. In 2.4.3 every new release needed a manual `finOpsBuildTrainMap` entry; nothing has to be maintained now.
- The map is printed in the log, e.g. "Release map from Microsoft's PQU schedule (30 PQU rows): 10.0.46 = 10.0.2428.x, ...".
- `finOpsBuildTrainMap` is now an emergency override only. Precedence: built-in fallback, then Microsoft's schedule, then the override.

### Added

- `finOpsScheduleUrl` (optional): where the schedule is read from. `none` disables the download. You never need to set it.

### Fail-safe behaviour

- If the schedule cannot be downloaded, or no usable rows are found (page format changed), the built-in map (10.0.46 to 10.0.49) is used and the log shows a warning. Environments on a newer release are skipped, not guessed.
- A build that the schedule lists under two different releases is treated as unknown and skipped, even if the built-in map has it.

### Documentation

- README, `docs/parameters.md`, `docs/setup.md`, the pipeline header and CONTRIBUTING no longer ask anyone to maintain a map. `docs/permissions.md` notes the outbound HTTPS access to `raw.githubusercontent.com` the agent needs (Microsoft-hosted agents have it).

## [2.4.3] - 2026-10-18

### Fixed

- **The release train is no longer read from the F&O Provisioning App Anchor Solution.** Microsoft has confirmed that this Dataverse record is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API that this pipeline uses. In 2.4.2 the train came from it, so it went stale after the pipeline's first apply: the ten environments moved to 10.0.49.3 in the 2.4.1 incident still read 10.0.48, and 2.4.2 would have skipped every 10.0.49 PQU for them (and treated 10.0.49 patches as a "version update"). The Anchor Solution is now used only to detect that F&O is installed, never its version.
- **Multi-version `finopsversions` responses were read as "no versions listed".** When the route returned a bare JSON array with two or more entries, `ConvertTo-FinOpsVersionList` probed `$Json.value` (and similar) on the array. PowerShell member enumeration returns one `$null` per entry, which is truthy for two or more entries, so the real list was replaced by `$null`s. Single-entry responses and responses wrapped in `{"value": [...]}` were unaffected. The parser now only unwraps an object, never an array.
- **F&O detection depended on package order.** `Get-FinOpsMarkerPackage` returned the first installed package whose display name contained "finance and operations". If another such app (for example a virtual entity solution) was listed first, the wrong package was treated as the provisioning app and the real one was sent to the Phase 1 install loop. Unique-name markers are now checked across all packages first, and the display-name fallback ignores virtual entity, dual-write and package manager apps.
- **An F&O environment whose Dataverse read failed vanished from the F&O phase.** Detection now happens before the Dataverse read, and the F&O phase no longer needs anything from Dataverse.

### Added

- **Release train from the live application build.** `applicationVersion` from `finopsproperties` (for example `10.0.2645.136`) is mapped by build prefix to its release train. Built-in map from Microsoft's PQU release schedule: `10.0.2428` = 10.0.46, `10.0.2527` = 10.0.47, `10.0.2645` = 10.0.48, `10.0.2790` = 10.0.49. The live train is shown on every environment line, e.g. `10.0.2645.136 [10.0.48]`.
- **`finOpsBuildTrainMap`** variable: extra prefix-to-train entries such as `10.0.2900=50`, so a new release needs no code change. The effective map is printed under Effective settings; malformed entries are ignored with a warning. An unknown prefix skips the apply (unless scope is `Any`) and the log names the prefix to add.
- **Lower-train guard, in every scope.** A version on a lower train than the live build is never applied, whether chosen automatically or set in `finOpsTargetVersion`. New counter "skipped (lower train)".

### Changed

- **`VersionUpdate` is bounded.** It now selects only the **next** release train (current + 1) and only versions staged `GeneralAvailability` or `QualityUpdate`. In 2.4.2 it accepted any higher train and any stage, so one run could jump several trains or apply a preview build, including on `UnifiedProduction`. A deliberate multi-train move now needs `Any` plus an explicit `finOpsTargetVersion`.
- Power Platform and BAP tokens are refreshed once they are 45 minutes old, so long runs stay inside token lifetime within the 180-minute job timeout.
- The Dataverse managed-solution query no longer uses `$top`, which suppressed `@odata.nextLink` paging.
- An app install accepted without an operation id now counts in "Update operations triggered".
- The `VersionUpdate` skip line now reads "no version update (next train) available for 10.0.xx".

### Documentation

- README, `docs/parameters.md`, `docs/setup.md` and the pipeline header describe the live-build train, the build map and how to extend it each release, the lower-train guard and the bounded `VersionUpdate`. `docs/setup.md` has a step-by-step for adding a new release.
- CONTRIBUTING invariant 6 now forbids using the Anchor Solution version for any F&O decision. Invariant 7 adds "take inputs from live state", bounding, and "do not rely on unverified platform refusals". New traps: member enumeration on arrays, `$top` with paging.

## [2.4.2] - 2026-10-06

> **Superseded by 2.4.3.** Its release train came from the Anchor Solution, which only changes on LCS-driven updates and goes stale after the first apply through this pipeline. `VersionUpdate` could also jump several trains or pick a non-released build, and multi-version responses could be read as "no versions listed".

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
