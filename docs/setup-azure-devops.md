# Setup: Azure DevOps

This guide takes you from nothing to a working Azure DevOps pipeline: the service principal, the Azure DevOps configuration, and the first run. Running on GitHub instead? See [setup-github.md](setup-github.md). Upgrading from v2? See [upgrading-to-v3.md](upgrading-to-v3.md).

Two pipelines are included. Pick one:

| Pipeline | Sign-in | Status |
|---|---|---|
| `azure-pipelines.yml` | Client secret in the variable group | Recommended start |
| `azure-pipelines-federated.yml` | Workload identity federation: no secret stored anywhere | Preview: verify with a Plan-only run first ([section 9](#federated-sign-in-preview)) |

Both run the same three stages:

```
Plan  ->  Apply: non-production  ->  Apply: production
          (only if the plan has      (only if the plan has production
           non-production actions)    actions; deployment to the Azure
                                      DevOps environment d365-production)
```

**Plan** reads the whole tenant and writes the plan and the run summary (Extensions tab). It changes nothing. The two **Apply** stages apply their part of the plan, re-checking each action against the live tenant first.

Read [permissions.md](permissions.md) alongside this guide. The permissions step is the most common reason a fresh tenant fails.

## 1. Create the service principal

- In the Microsoft Entra admin center, go to **Entra ID > App registrations > New registration**.
- Give it a clear name, for example `d365-tenant-app-updater`.
- Leave the redirect URI empty. This is an app-only (client credentials) flow.
- Register the app.
- Note the **Application (client) ID** and the **Directory (tenant) ID**.
- Go to **Certificates & secrets > New client secret**, create one, and copy the value now. You cannot read it again later. (Skip this for `azure-pipelines-federated.yml`.)

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

The pipeline needs only three variables to run. Everything else has a built-in default and is optional. Existing v2 variable groups work unchanged.

- In Azure DevOps, go to **Pipelines > Library > + Variable group**.
- Name it exactly `D365-TenantAppUpdater` (or update the group name in `azure-pipelines.yml`).
- Add the three required variables:

  | Name | Value | Secret |
  |---|---|---|
  | `ClientId` | Application (client) ID | No |
  | `ClientSecret` | The client secret value | **Yes** |
  | `TenantId` | Directory (tenant) ID | No |

- Optionally add any override variables you want (see [parameters.md](parameters.md)). Common choices:
  - `productionEnvironments = Training` (treat a sandbox as production; production environments are held until non-production runs a version, `productionRing` is on by default)
  - `environmentExclude = Production` (never touch production at all)
  - `finOpsApplyVersion = true` (enable F&O version apply; **changes environments**)
  - `finOpsUpdateScope = VersionUpdate` (opt into the next release train instead of the default PQU on the current train)
- Save.

There is no `pipelineName`, `agentVmImage`, or endpoint variable to set. The run name and agent image are fixed in the YAML, and all API endpoints and versions are script defaults you can override only if you ever need to.

## 4. Add the pipeline

- Push this repository to your Git provider, or import it into Azure Repos.
- In Azure DevOps, go to **Pipelines > New pipeline**.
- Point it at your repository and select the existing `azure-pipelines.yml`.
- Save (do not run yet).
- Authorize the pipeline to use the variable group: open the variable group > **Pipeline permissions** > add this pipeline.
- On the first run that has production actions, Azure DevOps creates the environment **d365-production** (Pipelines > Environments) and may ask you to permit the pipeline to use it. Approve once.

### Optional: a person approves production

The production stage is a deployment to the Azure DevOps environment `d365-production`. By default it has no checks, so production follows automatically once non-production proves a version. To require approval:

- **Pipelines > Environments > d365-production > Approvals and checks > + > Approvals**, add the approvers, Create.

The run then waits at **Apply: production** until someone approves, and shows the plan's production actions in the summary of the Plan stage. Apply re-checks every action when it finally runs, so a late approval never installs something different from what was planned.

## 5. First run (plan only)

- Run the pipeline manually.
- Set the **Plan only (do not install or apply)** dropdown to `true`. Only the Plan stage runs; both Apply stages are skipped.
- Open the run's **Extensions** tab (or the `plan` artifact's `summary.md`). Confirm it shows:
  - the environments in scope, A to Z, each with its ring (Production or NonProduction)
  - the **Planned** actions, and anything **Held for production** with the reason
  - the **Finance and Operations** table, if you have F&O
  - **Needs attention**, if an environment could not be read (usually a missing application user, see [permissions.md](permissions.md))
- The log has the same per environment, in the same order, plus the **Effective settings** block.
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

### Where the release train comes from (nothing to maintain)

The script reads `applicationVersion` from `finopsproperties` on every run (for example `10.0.2645.136`) and maps its build prefix to a release train. Every PQU of a release shares one prefix.

The map is built **automatically** on every run from Microsoft's [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule): the pipeline downloads the page's public source and reads each "10.0.xx PQU-n" row with its "Application Version". When Microsoft publishes a new release, the next run knows it. There is nothing to add or update.

- The log shows the map it built, e.g. "Release map from Microsoft's PQU schedule (30 PQU rows): 10.0.46 = 10.0.2428.x, ...".
- If the download fails (no outbound access to `raw.githubusercontent.com`, or the page changed format), the log shows a warning and the built-in map (10.0.46 to 10.0.49) is used instead.
- An environment on a release that is still unknown is skipped, never guessed.

### Why the F&O Provisioning App Anchor Solution is not used

Microsoft has confirmed that the Anchor Solution's version in Dataverse is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API that this pipeline uses. After the first apply through this pipeline it is permanently stale. v2.4.2 read the release train from it, so environments it had already updated were misread. The script now uses the Anchor Solution only to detect that F&O is installed, never its version.

### Upgrading from v2.4.0, v2.4.1 or v2.4.2 (history)

- **v2.4.0 and v2.4.1** decided scope from `releaseStage` alone, so `QualityUpdate` could move environments to a new release train.
- **v2.4.2** fixed that, but read the train from the Anchor Solution, which goes stale after the first apply through this pipeline. Its `VersionUpdate` could also jump several trains or pick a non-released build, and a bare multi-version response was reported as "no versions listed".

Use v2.4.3 or later (v3.0.0 includes every fix) before running with `finOpsApplyVersion = true`. No variable changes are needed for releases 10.0.46 to 10.0.49. Run once with **Plan only** set to `true` and check the `[10.0.xx]` train on each environment line: environments that previously showed "no versions listed" or were skipped may now show a planned apply.

### If you have `updateFinOpsVersion` or `finOpsInventory` from an earlier version

Both are retired. Delete them from the variable group. If either is still present, the script logs a one-time warning naming it, but treats it as if it were not there.

### A known, expected platform behaviour: `finopsversions` route flakiness

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real version data on the next, for the identical environment, token, and api-version, with no configuration change in between. This is treated as an expected platform condition and reported factually per environment. It is **not** counted as a script failure and is **not** evidence of a permissions or configuration problem. If you see it, simply re-run.

## 7. Optional: enable the PAC CLI fallback

If you want the pipeline to attempt a PAC CLI install for custom-install apps:

- Set the **Try PAC CLI fallback** dropdown to `true`, or add `usePacFallback = true`.
- When the fallback is on, the pipeline automatically installs the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent.
- The fallback signs in with the client secret, so it is ignored (with a warning) in `azure-pipelines-federated.yml`.

The script tries `pac app-management install-application-package` first and falls back to the legacy `pac application install`. The fallback authenticates with the same service principal. It is best effort: for apps that genuinely require the Power Platform Admin Center wizard it may still be blocked, in which case the app is reported as manual install required.

The Finance and Operations phase does **not** use the CLI. It calls the REST API directly.

## 8. Schedule it (optional)

To keep the tenant continuously up to date, open `azure-pipelines.yml`, uncomment the `schedules` block, adjust the cron expression, and commit.

With the production ring on (the default), a nightly schedule gives you: non-production updates every night, production updates the night after a non-production environment has run the version. Add `productionSoakDays` to wait longer for apps, or an approval on `d365-production` (section 4) to keep a person in the loop.

If you schedule the pipeline, decide deliberately whether `finOpsApplyVersion` should be on, and whether `finOpsUpdateScope` should stay at the safer `QualityUpdate` default or be widened to `VersionUpdate`. An unattended run that applies a full release-wave jump is a different risk profile from an unattended run that only applies same-train patches.

## 9. Federated sign-in (preview)

`azure-pipelines-federated.yml` signs in without a client secret. The pipeline requests a short-lived OIDC token for a service connection, and Microsoft Entra ID exchanges it for an access token of the same app registration. This pipeline is **preview**: the token exchange is the documented Azure DevOps mechanism, but run it with **Plan only** first to confirm it in your organization.

1. **Create the service connection.** Project settings > Service connections > New > **Azure Resource Manager** > **Workload identity federation (manual)**.
   - Name it `d365-tenant-app-updater-wif` (or change `serviceConnection` at the top of `azure-pipelines-federated.yml`).
   - Use the **same app registration** as the updater: its Application (client) ID and Directory (tenant) ID. The scope (subscription or management group) does not matter to the updater; it only signs in as the app.
   - Azure DevOps shows an **Issuer** and a **Subject identifier**. Keep the page open.
2. **Add the federated credential.** Entra ID > App registrations > the app > **Certificates & secrets > Federated credentials > Add credential** > **Other issuer**. Paste the Issuer and Subject identifier. Audience: `api://AzureADTokenExchange`. Save.
3. Finish the service connection in Azure DevOps (Verify and save).
4. **Find the service connection ID.** Open the service connection; the ID is the `resourceId` value in the browser's address bar. Add it to the variable group as `serviceConnectionId`.
5. Add the pipeline from `azure-pipelines-federated.yml` and authorize it to use the variable group and the service connection.
6. Run with **Plan only** = `true`. The log shows `Sign-in : Federated (AzureDevOps OIDC)`.

`ClientId` and `TenantId` are optional in this pipeline (the service connection supplies them). The `ClientSecret` variable is not used and can be deleted from the group once the federated pipeline works.

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
| "current release train unknown (build 10.0.xxxx.x is not in Microsoft's PQU schedule or the built-in map yet)" | The release is newer than Microsoft's schedule, or the schedule could not be downloaded | Usually resolves itself on a later run once Microsoft publishes the release. If the log also shows "PQU schedule was not used", check the agent's outbound access to `raw.githubusercontent.com`. |
| "Microsoft's PQU schedule was not used - ..." | The schedule download failed or the page format changed | The built-in map is used meanwhile. Check outbound access from the agent; nothing else is required. |
| "current release train unknown (no application version reported)" | `finopsproperties` returned no `applicationVersion` | Re-run. If it persists, check the environment in PPAC. |
| "every listed version is on a lower train than 10.0.xx" | The list only had versions older than the live build | Expected. Nothing to apply. |
| Environments moved to a new release train with `QualityUpdate` scope | Running v2.4.0 or v2.4.1 | Upgrade to v2.4.4. |
| "no versions listed" although PPAC shows updates | Running v2.4.2 or earlier, with a multi-version response | Upgrade to v2.4.3. |
| "requires PowerShell 7.2" | Running under Windows PowerShell 5.1 | v3 requires PowerShell 7.2 or later. The pipelines use it already; locally, run with `pwsh`. |
| **Held for production** for a version | No non-production environment in scope runs it yet | Expected (`productionRing = true`). It is applied once non-production has it. Set `productionRing = false` to update everything at once. |
| `Stale` in an Apply stage | The available version changed, or the F&O version is no longer offered, between Plan and Apply | Expected. The next run plans again. |
| `TimedOut` for an app install | The install is still running after `waitForInstallsMinutes` | Not a failure. The next run sees the result. Increase `waitForInstallsMinutes` if you want to wait longer. |
| Run is orange (SucceededWithIssues) | Something could not be read or an install failed | See **Needs attention** in the summary. Set `failOnIssues = true` to fail the run instead. |
| "Could not get an Azure DevOps OIDC token" | Federated pipeline: wrong `serviceConnectionId`, or the pipeline is not authorized for the service connection | Check section 9, steps 4 and 5. |
| `AADSTS70021: No matching federated identity record` | The federated credential's issuer or subject does not match | Copy them again from the service connection (section 9, step 2). |
| A warning names `updateFinOpsVersion` or `finOpsInventory` | A retired variable is still in the group | Delete it. It has no effect either way. |
