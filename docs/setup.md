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
  - `finOpsUpdateScope = VersionUpdate` (opt into a new release train instead of the default same-train patch)
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
TPM-DEV04: 10.0.2645.136 (UnifiedDeveloper) - no PQU version available. New version available: 10.0.49.2 [Status: GeneralAvailability]
```

Expand the environment's collapsible group to see additional detail: AOS counts, demo dataset, and the F&O Provisioning App Anchor Solution version (shown for reference only - see the note below on why it is never used to make a decision).

### Version apply (opt-in, changes environments)

Set `finOpsApplyVersion = true` in the variable group, or set the **Apply F&O version** dropdown to `true` for a single run. The log prints a warning block when it is enabled, and nothing else in the configuration can turn this on: not a default, not another variable, not the underlying route becoming available on its own.

Run with **Plan only** set to `true` first.

### Choosing an update scope

`finOpsUpdateScope` controls **which kind** of available version is eligible:

- `QualityUpdate` (default, shown as **PQU** in the log) - only an in-place patch on the environment's current release train.
- `VersionUpdate` (shown as **version update**) - only a move to a new release train.
- `Any` - the numerically highest version available, regardless of kind.

This is matched directly against Microsoft's own `releaseStage` field on each version returned by the platform - not derived, not guessed. If your environments are already fully caught up on their current train, `QualityUpdate` scope will correctly report "no PQU version available" rather than jumping to the next release wave on your behalf; switch to `VersionUpdate` when you deliberately want that move.

Optional refinements, all inert unless `finOpsApplyVersion = true`:

- `finOpsEnvironmentFilter` - restrict the apply phase to specific environments, while Phase 1 and inventory still run everywhere.
- `finOpsTargetVersion` - apply a specific version instead of the highest matching scope.
- `finOpsDeploymentTypes` - control which deployment types are eligible for a version apply. The default excludes LCS managed environments.

### Why the F&O Provisioning App Anchor Solution is not used to decide anything

An earlier version of this project used the Anchor Solution's Dataverse-registered version as the reference point for classifying available updates. This was confirmed live to be unreliable: ten environments sharing the **identical** live application build reported **two different** Anchor Solution readings in the same run. The reason is structural: Microsoft's own automated Unified environment service update rollout does not update that Dataverse record; only a Dataverse-level solution operation (an environment copy from an already-updated source, or an explicit solution import) does. So an environment updated the normal way can carry a stale Anchor Solution version indefinitely, while its live application build is completely current.

The fix was to stop deriving classification from that value entirely, and instead match directly against Microsoft's own `releaseStage` label on each version. The Anchor Solution value is still shown, under `dumpDiagnostics`, purely as a labeled reference - never as the basis for a decision.

### If you have `updateFinOpsVersion` or `finOpsInventory` from an earlier version

Both are retired. Delete them from the variable group. If either is still present, the script logs a one-time warning naming it, but treats it as if it were not there.

### A known, expected platform behaviour: `finopsversions` route flakiness

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real version data on the next, for the identical environment, token, and api-version, with no configuration change in between. This is treated as an expected platform condition and reported factually per environment - it is **not** counted as a script failure, and it is **not** evidence of a permissions or configuration problem. If you see it, simply re-run.

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
| "no PQU version available" every run | The environment is already fully caught up on its current release train | Expected if there is genuinely no newer same-train patch yet. Switch `finOpsUpdateScope` to `VersionUpdate` if you want the next release train instead. |
| F&O phase skipped with a PowerShell version warning | Running under Windows PowerShell 5.1 | Use `pwsh: true` in the task, or PowerShell 7 locally |
| A warning names `updateFinOpsVersion` or `finOpsInventory` | A retired variable is still in the group | Delete it. It has no effect either way. |
