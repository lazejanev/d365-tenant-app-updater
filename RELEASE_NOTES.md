# Release Notes

## v2.4.3 - 2026-10-18

**Safety hardening on top of v2.4.2. Upgrade before running with `finOpsApplyVersion = true`.**

### What changed

| Area | v2.4.2 | v2.4.3 |
|---|---|---|
| `QualityUpdate` (PQU) | Staged `QualityUpdate` on the current train | Unchanged |
| `VersionUpdate` | Any **higher** train, any stage | The **next** train only, staged `GeneralAvailability` or `QualityUpdate` |
| `Any` | Highest version | Unchanged |
| Version at or below the Anchor Solution | Left to the apply endpoint (unverified) | **Never applied**, in every scope |
| `finopsversions` bare array with 2+ entries | Read as "no versions listed" | Parsed correctly |
| F&O detection | First "finance and operations" name wins | Unique names first, then a filtered name fallback |
| F&O environment with a failed Dataverse read | Missing from the inventory | Inventoried, apply skipped |

### Why

- **Never older.** The Anchor Solution lags the live build but never runs ahead of it, so a version at or below it cannot be an upgrade. v2.4.2 relied on the apply endpoint to refuse such a request. That was never verified, so the script now refuses it itself.
- **One train at a time.** v2.4.2's `VersionUpdate` would take the highest version on any higher train. That could move 10.0.48 straight to 10.0.50, or to a preview build, in one unattended run. For a deliberate multi-train move, use `Any` with an explicit `finOpsTargetVersion`.
- **Parsing.** PowerShell member enumeration turned a bare multi-version array into a list of `$null`s. If an environment always showed "no versions listed" while PPAC offered updates, this was the cause.

### Also fixed

- Tokens are refreshed after 45 minutes on long runs.
- The Dataverse solution query no longer uses `$top`, which disabled paging.
- An install accepted without an operation id now counts as triggered.

### Upgrade notes

- Replace `scripts/Update-TenantApps.ps1`. No variable changes.
- Run once with `whatIf = true`. Environments that previously showed "no versions listed" may now show real versions and a planned apply. Check them before a live run.
- If you relied on `VersionUpdate` to jump more than one train, switch that run to `Any` with an explicit `finOpsTargetVersion`.

## v2.4.2 - 2026-10-06

> **Superseded by v2.4.3.** Its `VersionUpdate` scope was not bounded, and multi-version responses could be read as "no versions listed".

**Critical fix. Upgrade before running with `finOpsApplyVersion = true`.**

### What went wrong

In v2.4.0 and v2.4.1, `finOpsUpdateScope = QualityUpdate` selected any version that Microsoft staged `QualityUpdate`. That label describes the build itself, not whether the build is on your environment's release train. Once 10.0.49 shipped, its patches (for example 10.0.49.3) were also staged `QualityUpdate`, so environments on 10.0.48 were moved to 10.0.49. This was confirmed live in a scheduled run.

### What changed

| Scope | v2.4.0 / v2.4.1 | v2.4.2 |
|---|---|---|
| `QualityUpdate` (PQU) | Staged `QualityUpdate` | Staged `QualityUpdate` **and** on the environment's current release train |
| `VersionUpdate` | Staged anything other than `QualityUpdate` | On a **higher** release train |
| `Any` | Highest version | Highest version (unchanged) |

- The current release train is the 3rd segment of the F&O Provisioning App Anchor Solution version (the `48` in `10.0.48.6`). Only the train is used.
- If the train cannot be determined, the apply is skipped unless the scope is `Any`.
- Log lines now name the train, for example "no PQU version available for 10.0.48", and the diagnostic detail shows "Current train".

### Known limitation

The Anchor Solution is not updated by every update path. If an environment has moved to a new train but its Anchor Solution still shows the old one, `QualityUpdate` skips it, as long as `finopsversions` offers no version on the stale train. v2.4.3 adds a guard so that nothing at or below the Anchor is ever applied.

### Upgrade notes

- Replace `scripts/Update-TenantApps.ps1`. No variable changes.
- Run once with `whatIf = true` and check each environment's "Current train".
- If v2.4.0 or v2.4.1 already moved environments to a new train, those updates are not reverted by this release.

## v2.4.1 - 2026-09-27

> **Affected by the release-train bug fixed in v2.4.2.**

Wording only. `QualityUpdate` displays as **PQU**, `VersionUpdate` as **version update**, brackets read `[Status: stage]`, and the available-versions diagnostic is labeled "New version available".

## v2.4.0 - 2026-09-27

> **Affected by the release-train bug fixed in v2.4.2.**

- Removed patch-level classification based on the F&O Provisioning App Anchor Solution, whose patch digit was shown to lag behind the live environment.
- Matched `finOpsUpdateScope` against `releaseStage` only. This was incomplete for `QualityUpdate` and is corrected in v2.4.2.
- Shorter Finance and Operations output: one compact headline per environment, explanation printed once.

## v2.3.x series - 2026-09-19 through 2026-09-26

- **v2.3.0**: `finOpsApplyVersion` as the single Finance and Operations on/off switch. Dead settings removed. Transport failures reported honestly. PowerShell 7 required for this phase.
- **v2.3.1**: The apply call's own response became the sole authority on whether an apply is needed.
- **v2.3.2**: Admin Mode detection for Phase 1.
- **v2.3.3**: `finOpsUpdateScope` introduced.
- **v2.3.4**: Fixed a regression that reintroduced a cross-scheme version comparison.
- **v2.3.5**: The F&O Provisioning App Anchor Solution excluded from Phase 1's generic install loop.
- **v2.3.6**: One headline per environment; inventory table unconditional; `dumpSolutionCatalog` split out.
- **v2.3.7 / v2.3.8**: Collapsible groups kept, with the group label set to the headline.
- **v2.3.9**: Identified the Anchor Solution lag.

## v2.2.0 - 2026-09-18

Finance and Operations inventory and version update against the documented Power Platform routes, gated behind a live route check.

## v2.0.0 - 2026-08-18

Required configuration reduced to `ClientId`, `ClientSecret`, `TenantId`.

## v1.x series - 2026-08-16 through 2026-08-18

Initial public release and early hardening: environment discovery, never-downgrade version comparison, `AppExclude` / `EnvironmentExclude`, Custom Install Experience detection, optional PAC CLI fallback.
