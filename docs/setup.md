# Setup

This guide takes you from nothing to a working pipeline. It has three parts: the service principal, the Azure DevOps configuration, and the first run.

Read [permissions.md](permissions.md) alongside this guide. The permissions step is the most common reason a fresh tenant fails.

## 1. Create the service principal

- In the Microsoft Entra admin center, go to **Entra ID > App registrations > New registration**.
- Give it a clear name, for example `d365-tenant-app-updater`.
- Leave the redirect URI empty. This is an app-only (client credentials) flow.
- Register the app.
- Note the **Application (client) ID** and the **Directory (tenant) ID**.
- Go to **Certificates & secrets > New client secret**, create one, and copy the value now. You cannot read it again later.

## 2. Grant permissions and register as a management app

Follow [permissions.md](permissions.md). In short:

- Register the service principal as a Power Platform management application:

  ```powershell
  Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
  Add-PowerAppsAccount
  New-PowerAppManagementApp -ApplicationId <application-client-id>
  ```

- Add the service principal as an **application user with a security role** (for example System Administrator) in **each target environment's Dataverse**. This is required to read managed-solution versions and to install apps.

## 3. Create the Azure DevOps variable group

The pipeline needs only three variables to run. Everything else has a built-in default and is optional.

- In Azure DevOps, go to **Pipelines > Library > + Variable group**.
- Name it exactly `D365-TenantAppUpdater` (or update the group name in `azure-pipelines.yml`).
- Add the three required variables:

  | Name | Value | Secret |
  |---|---|---|
  | `ClientId` | Application (client) ID | No |
  | `ClientSecret` | The client secret value | **Yes** |
  | `TenantId` | Directory (tenant) ID | No |

- Optionally add any override variables you want (see [parameters.md](parameters.md)). Common choices:
  - `environmentExclude = Production` (protect production)
  - `finOpsApplyVersion = true` (enable F&O version apply; **changes environments**)
  - `finOpsUpdateScope = VersionUpdate` (opt into the next release train instead of the default PQU on the current train)
  - `finOpsBuildTrainMap = 10.0.2900=50` (only when Microsoft ships a release newer than 10.0.49; see section 6)
- Save.

There is no `pipelineName`, `agentVmImage`, or endpoint variable to set. The run name and agent image are fixed in the YAML, and all API endpoints and versions are script defaults you can override only if you ever need to.

## 4. Add the pipeline

- Push this repository to your Git provider, or import it into Azure Repos.
- In Azure DevOps, go to **Pipelines > New pipeline**.
- Point it at your repository and select the existing `azure-pipelines.yml`.
- Save (do not run yet).
- Authorize the pipeline to use the variable group: open the variable group > **Pipeline permissions** > add this pipeline.

## 5. First run (preview)

- Run the pipeline manually.
- Set the **Plan only (do not install or apply)** dropdown to `true` so the first run reports without changing anything.
- To be extra safe, set `environmentExclude` to your production environment name for the first runs.
- Confirm the log shows:
  - the **Effective settings** block
  - `Acquired Power Platform and BAP tokens`
  - `Found N Dataverse environment(s)`
  - per-environment installed vs available diagnostics
  - the **Finance and Operations** section, with one compact line per environment
  - a **TENANT SUMMARY** at the end
- When the plan looks right, run again with **Plan only** set to `false`.

## 6. Finance and Operations

There is a single on/off variable, `finOpsApplyVersion` (default `false`), plus a scope control, `finOpsUpdateScope` (default `QualityUpdate`).

### Inventory (always on, read-only)

No configuration needed. It runs on every pipeline execution, for every environment where Finance and Operations is installed, regardless of `finOpsApplyVersion`. Per environment, the log shows one compact line, for example:

```
Dev04: 10.0.2645.136 [10.0.48] (UnifiedDeveloper) - no PQU version available for 10.0.48. New version available: 10.0.49.3 [Status: QualityUpdate]
```

> The environment name above is an illustrative placeholder. Your own log will show your actual environment display names.

The `[10.0.48]` is the release train of the live build. Expand the environment's collapsible group to see additional detail: AOS counts, demo dataset, and the **Current train** with the build prefix it came from.

### Version apply (opt-in, changes environments)

Set `finOpsApplyVersion = true` in the variable group, or set the **Apply F&O version** dropdown to `true` for a single run. The log prints a warning block when it is enabled, and nothing else in the configuration can turn this on.

Run with **Plan only** set to `true` first.

### Choosing an update scope

`finOpsUpdateScope` controls **which kind** of available version is eligible:

- `QualityUpdate` (default, shown as **PQU**) - a version staged `QualityUpdate` **on the environment's current release train**. An environment on 10.0.48 can get 10.0.48.7, never 10.0.49.x.
- `VersionUpdate` (shown as **version update**) - a version on the **next** release train only (10.0.48 to 10.0.49, never 10.0.50 in one run), staged `GeneralAvailability` or `QualityUpdate`.
- `Any` - the numerically highest version available, no train or stage restriction. Combine it with an explicit `finOpsTargetVersion` for a deliberate multi-train jump.

Microsoft's `releaseStage` alone is not enough: it describes the build itself, so a quality update on a newer train (for example 10.0.49.3) is also staged `QualityUpdate`. That is why the train check exists.

The environment's current train comes from its **live application build** (see below). If it cannot be determined, the apply is **skipped** unless the scope is `Any`.

In every scope, a version on a lower train than the live build is never applied.

Optional refinements, all inert unless `finOpsApplyVersion = true`:

- `finOpsEnvironmentFilter` - restrict the apply phase to specific environments, while Phase 1 and inventory still run everywhere.
- `finOpsTargetVersion` - apply a specific version instead of the highest matching scope.
- `finOpsDeploymentTypes` - control which deployment types are eligible for a version apply. The default excludes LCS managed environments.

### Where the release train comes from, and keeping the map current

The script reads `applicationVersion` from `finopsproperties` on every run (for example `10.0.2645.136`) and maps its build prefix to a release train. Every PQU of a release shares one prefix. The built-in map covers 10.0.46 (`10.0.2428`), 10.0.47 (`10.0.2527`), 10.0.48 (`10.0.2645`) and 10.0.49 (`10.0.2790`), taken from Microsoft's [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule).

**When Microsoft ships a new release** (roughly once a quarter):

1. Open that page and find the new release's first PQU row. Note the build prefix in the "Application Version" column, for example `10.0.2900` from `10.0.2900.75`.
2. Add `finOpsBuildTrainMap = 10.0.2900=50` to the `D365-TenantAppUpdater` variable group. Separate several entries with commas.
3. The next run prints the effective map under **Effective settings**.

Until a release is added, environments on it are skipped with a log line naming the prefix to add. Nothing is guessed.

### Why the F&O Provisioning App Anchor Solution is not used

Microsoft has confirmed that the Anchor Solution's version in Dataverse is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API that this pipeline uses. After the first apply through this pipeline it is permanently stale. v2.4.2 read the release train from it, so environments it had already updated were misread. The script now uses the Anchor Solution only to detect that F&O is installed, never its version.

### Upgrading from v2.4.0, v2.4.1 or v2.4.2

- **v2.4.0 and v2.4.1** decided scope from `releaseStage` alone, so `QualityUpdate` could move environments to a new release train.
- **v2.4.2** fixed that, but read the train from the Anchor Solution, which goes stale after the first apply through this pipeline. Its `VersionUpdate` could also jump several trains or pick a non-released build, and a bare multi-version response was reported as "no versions listed".

Replace `scripts/Update-TenantApps.ps1` with v2.4.3 before running with `finOpsApplyVersion = true`. No variable changes are needed for releases 10.0.46 to 10.0.49. Run once with **Plan only** set to `true` and check the `[10.0.xx]` train on each environment line: environments that previously showed "no versions listed" or were skipped may now show a planned apply.

### If you have `updateFinOpsVersion` or `finOpsInventory` from an earlier version

Both are retired. Delete them from the variable group. If either is still present, the script logs a one-time warning naming it, but treats it as if it were not there.

### A known, expected platform behaviour: `finopsversions` route flakiness

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real version data on the next, for the identical environment, token, and api-version, with no configuration change in between. This is treated as an expected platform condition and reported factually per environment. It is **not** counted as a script failure and is **not** evidence of a permissions or configuration problem. If you see it, simply re-run.

## 7. Optional: enable the PAC CLI fallback

If you want the pipeline to attempt a PAC CLI install for custom-install apps:

- Set the **Try PAC CLI fallback** dropdown to `true`, or add `usePacFallback = true`.
- When the fallback is on, the pipeline automatically installs the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent.

The script tries `pac app-management install-application-package` first and falls back to the legacy `pac application install`. The fallback authenticates with the same service principal. It is best effort: for apps that genuinely require the Power Platform Admin Center wizard it may still be blocked, in which case the app is reported as manual install required.

The Finance and Operations phase does **not** use the CLI. It calls the REST API directly.

## 8. Schedule it (optional)

To keep the tenant continuously up to date, open `azure-pipelines.yml`, uncomment the `schedules` block, adjust the cron expression, and commit.

If you schedule the pipeline, decide deliberately whether `finOpsApplyVersion` should be on, and whether `finOpsUpdateScope` should stay at the safer `QualityUpdate` default or be widened to `VersionUpdate`. An unattended run that applies a full release-wave jump is a different risk profile from an unattended run that only applies same-train patches.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Forbidden` on the environments call | Service principal is not registered as a management app | Run `New-PowerAppManagementApp` (see permissions.md) |
| `invalid_client` / `AADSTS7000218` on token | Wrong secret, expired secret, or wrong tenant | Recreate the secret and confirm `TenantId` |
| Failed to read Dataverse solution versions | Missing application user or role in that environment | Add the app user with a security role in Dataverse |
| An app shows as manual install required | It uses the PPAC Custom Install Experience | Install it in PPAC, or add it to `appExclude` |
| An environment you expected was skipped | It is in `environmentExclude`, not in `environmentFilter`, or not Dataverse-linked | Check the Effective settings block and the environment list |
| More apps excluded than expected | A short `appExclude` value matched as a substring | Use the exact unique name or an explicit wildcard |
| `finopsversions returned HTTP 404 RouteNotFound` | Expected, intermittent platform behaviour | Re-run. See section 6. Not a permissions or config issue. |
| "no PQU version available for 10.0.xx" | No quality update exists yet on the environment's current release train | Expected. Switch `finOpsUpdateScope` to `VersionUpdate` if you want the next release train. |
| "no version update (next train) available for 10.0.xx" | Nothing released is offered on the next train, or only a later train is offered | Expected. For a deliberate multi-train move, use `Any` with an explicit `finOpsTargetVersion`. |
| "current release train unknown (build prefix 10.0.xxxx is not in the build -> train map ...)" | The environment is on a release the map does not know yet | Add the prefix to `finOpsBuildTrainMap`, e.g. `10.0.2900=50`. See section 6. |
| "current release train unknown (no application version reported)" | `finopsproperties` returned no `applicationVersion` | Re-run. If it persists, check the environment in PPAC. |
| "every listed version is on a lower train than 10.0.xx" | The list only had versions older than the live build | Expected. Nothing to apply. |
| Environments moved to a new release train with `QualityUpdate` scope | Running v2.4.0 or v2.4.1 | Upgrade to v2.4.3. |
| "no versions listed" although PPAC shows updates | Running v2.4.2 or earlier, with a multi-version response | Upgrade to v2.4.3. |
| F&O phase skipped with a PowerShell version warning | Running under Windows PowerShell 5.1 | Use `pwsh: true` in the task, or PowerShell 7 locally |
| A warning names `updateFinOpsVersion` or `finOpsInventory` | A retired variable is still in the group | Delete it. It has no effect either way. |
