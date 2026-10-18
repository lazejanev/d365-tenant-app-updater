# Release Notes

## v3.0.0 - 2026-10-18

**Production waits for proof. GitHub joins Azure DevOps. No secret needed.**

v3 keeps every v2 setting, so your variable group keeps working, and adds the controls a tenant-wide updater needs before it touches production.

- **Production ring (on by default).** Non-production environments update as soon as a version is available ("test and break fast"). A production environment only takes a version that a non-production environment already runs. Applies to Dynamics 365 apps and to Finance and Operations. Everything held back is listed with the reason. `productionRing = false` restores v2 behaviour.
- **Plan, then apply.** The pipeline now has three stages: Plan (reads the tenant, changes nothing), Apply non-production, Apply production. Add an approval to the `d365-production` environment if you want a person to sign off production. Apply re-checks every action against the live tenant first.
- **GitHub Actions.** The same module, rules and three jobs run on GitHub. See `docs/setup-github.md`.
- **No client secret.** Sign in with OpenID Connect on GitHub, or workload identity federation on Azure DevOps (preview). The secret remains supported, and works as a backup.
- **You see the outcome.** App installs are followed for up to 30 minutes and reported as succeeded, failed or still running. Every run publishes a summary on the run page and a JSON report.
- **A to Z.** Environments and apps are processed and reported in alphabetical order.
- **Tested.** 101 automated tests run on every change, on Linux and Windows, with no tenant needed.

**Upgrading:** PowerShell 7.2+ is now required for the whole run (Microsoft-hosted agents have it). Copy `src/` along with `scripts/`, and replace `azure-pipelines.yml`. Full guide: `docs/upgrading-to-v3.md`.

## v2.4.4 - 2026-10-18

**Nothing to maintain: the release map now updates itself.**

v2.4.3 worked out each environment's release from its live application build, but needed a manual `finOpsBuildTrainMap` entry for every new release. v2.4.4 removes that step. Every run downloads Microsoft's [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule) and builds the map from it, so when Microsoft publishes 10.0.50 the next run already knows it.

- **No configuration change.** Existing variable groups keep working. `finOpsBuildTrainMap` is now an emergency override only and can be removed.
- **Fail-safe.** If the schedule cannot be downloaded or parsed, the log shows a warning and the built-in map (10.0.46 to 10.0.49) is used. Environments on a newer, unknown release are skipped, not guessed. A build the schedule lists under two releases is skipped too.
- **Network.** The agent needs outbound HTTPS to `raw.githubusercontent.com`. Microsoft-hosted agents have it; see `docs/permissions.md` for self-hosted agents.
- New optional `finOpsScheduleUrl` (`none` disables the download).

## v2.4.3 - 2026-10-18

**Upgrade before running with `finOpsApplyVersion = true`.**

### The release train now comes from the live build

v2.4.2 read each environment's release train from the F&O Provisioning App Anchor Solution in Dataverse. Microsoft has confirmed that this record is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API that this pipeline uses. So it goes stale after the pipeline's first apply. The environments moved to 10.0.49.3 in the v2.4.1 incident still read 10.0.48: v2.4.2 would have skipped all their 10.0.49 PQUs.

v2.4.3 reads `applicationVersion` from `finopsproperties` on every run (for example `10.0.2645.136`) and maps its build prefix to the release, using the build numbers Microsoft publishes in the [PQU release schedule](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule):

| Build prefix | Release |
|---|---|
| `10.0.2428` | 10.0.46 |
| `10.0.2527` | 10.0.47 |
| `10.0.2645` | 10.0.48 |
| `10.0.2790` | 10.0.49 |

**When a new release ships**, add one entry to the new `finOpsBuildTrainMap` variable, for example `10.0.2900=50`. Until then, environments on that release are skipped and the log names the prefix to add.

### What changed

| Area | v2.4.2 | v2.4.3 |
|---|---|---|
| Current release train | Anchor Solution (stale after a PPAC/API update) | Live application build, via the build map |
| `QualityUpdate` (PQU) | Staged `QualityUpdate` on the current train | Unchanged rule, correct train |
| `VersionUpdate` | Any **higher** train, any stage | The **next** train only, staged `GeneralAvailability` or `QualityUpdate` |
| `Any` | Highest version | Unchanged, but never a lower train than the live build |
| `finopsversions` bare array with 2+ entries | Read as "no versions listed" | Parsed correctly |
| F&O detection | First "finance and operations" name wins | Unique names first, then a filtered name fallback |
| F&O environment with a failed Dataverse read | Missing from the F&O phase | Processed normally |

### Also fixed

- Tokens are refreshed after 45 minutes on long runs.
- The Dataverse solution query no longer uses `$top`, which disabled paging.
- An install accepted without an operation id now counts as triggered.

### Upgrade notes

- Replace `scripts/Update-TenantApps.ps1`. No variable changes are needed for 10.0.46 to 10.0.49.
- Run once with `whatIf = true`. Each environment line now shows its live train, e.g. `10.0.2790.83 [10.0.49]`. Environments that were skipped, or showed "no versions listed", may now show a planned apply. Check them before a live run.
- If you relied on `VersionUpdate` to jump more than one train, switch that run to `Any` with an explicit `finOpsTargetVersion`.

## v2.4.2 - 2026-10-06

> **Superseded by v2.4.3.** It read the release train from the Anchor Solution, which only changes on LCS-driven updates. Its `VersionUpdate` scope was not bounded, and multi-version responses could be read as "no versions listed".

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

The Anchor Solution is not updated by every update path. If an environment has moved to a new train but its Anchor Solution still shows the old one, `QualityUpdate` skips it. Microsoft later confirmed the Anchor Solution only changes on LCS-driven updates, so v2.4.3 reads the train from the live application build instead.

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
