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
  - the **Finance and Operations** section with the inventory table
  - a **TENANT SUMMARY** at the end
- When the plan looks right, run again with **Plan only** set to `false`.

## 6. Finance and Operations

There is a single Finance and Operations variable: `finOpsApplyVersion`, default `false`.

### Inventory (always on, read-only)

No configuration needed. It runs on every pipeline execution, for every environment where Finance and Operations is installed, whether `finOpsApplyVersion` is `true` or `false`. The log shows:

- application version and platform version
- deployment type
- AOS counts, demo dataset and scheduled actions
- a consolidated inventory table at the end

Nothing is changed. There is no variable to turn inventory off; it is one GET per F&O environment and does not warrant one.

### Version apply (opt-in, changes environments)

Set `finOpsApplyVersion = true` in the variable group, or set the **Apply F&O version** dropdown to `true` for a single run. The log prints a warning block when it is enabled, and nothing else in the configuration can turn this on: not a default, not another variable, not the underlying route becoming available on its own.

Run with **Plan only** set to `true` first.

Optional refinements, all inert unless `finOpsApplyVersion = true`:

- `finOpsEnvironmentFilter` - restrict the apply phase to specific environments, while Phase 1 and inventory still run everywhere.
- `finOpsTargetVersion` - apply a specific version instead of the latest available.
- `finOpsDeploymentTypes` - control which deployment types are eligible for a version apply. The default excludes LCS managed environments.

### If you have `updateFinOpsVersion` or `finOpsInventory` from an earlier version

Both are retired. Delete them from the variable group. If either is still present, the script logs a one-time warning naming it, but treats it as if it were not there: inventory still always runs, and apply is still governed solely by `finOpsApplyVersion`.

### What to expect regarding version apply

At the time of writing, the `finopsversions` route and its `apply` sub-route return `RouteNotFound` on this tenant, while `finopsproperties` returns data successfully. This has been confirmed two ways: directly over REST, and independently via Microsoft's `pac dynamics get-fin-ops-versions` / `apply-fin-ops-version` CLI commands, which construct and issue the identical request URL and receive the identical `RouteNotFound` response. When it happens you will see, per environment:

```
finopsversions returned HTTP 404 RouteNotFound.
finopsproperties succeeded for this environment, so the token, the
environment id and the api-version are accepted. This specific route
did not resolve on this endpoint.
```

This is expected and is **not** counted as a failure. Inventory still works. The apply logic is implemented and gated behind a live route check, so version updates begin working automatically once the route is available on your endpoint. No code change is required.

That automatic activation is exactly why `finOpsApplyVersion` is a separate, explicit, off-by-default switch. Leave it off and the route becoming available changes nothing for you.

LCS managed environments (`LCSSandbox`, `LCSProduction`) are reported as:

```
Version apply skipped. LCS managed environments are updated through
Lifecycle Services, not the Power Platform API. Inventory only.
```

That is by design.

## 7. Optional: enable the PAC CLI fallback

If you want the pipeline to attempt a PAC CLI install for custom-install apps:

- Set the **Try PAC CLI fallback** dropdown to `true`, or add `usePacFallback = true`.
- When the fallback is on, the pipeline automatically installs the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent.

The script tries `pac app-management install-application-package` first and falls back to the legacy `pac application install`. The fallback authenticates with the same service principal. It is best effort: for apps that genuinely require the Power Platform Admin Center wizard it may still be blocked, in which case the app is reported as manual install required.

The Finance and Operations phase does **not** use the CLI. It calls the REST API directly.

## 8. Schedule it (optional)

To keep the tenant continuously up to date, open `azure-pipelines.yml`, uncomment the `schedules` block, adjust the cron expression, and commit.

If you schedule the pipeline, decide deliberately whether `finOpsApplyVersion` should be on. An unattended run that applies application versions is a different risk profile from an unattended run that only installs Dataverse app updates.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Forbidden` on the environments call | Service principal is not registered as a management app | Run `New-PowerAppManagementApp` (see permissions.md) |
| `invalid_client` / `AADSTS7000218` on token | Wrong secret, expired secret, or wrong tenant | Recreate the secret and confirm `TenantId` |
| Failed to read Dataverse solution versions | Missing application user or role in that environment | Add the app user with a security role in Dataverse |
| An app shows as manual install required | It uses the PPAC Custom Install Experience | Install it in PPAC, or add it to `appExclude` |
| `InvalidApiVersion` on the environments call | An override set `bapApiVersion` to an unsupported value | Remove the override or set a supported version |
| An environment you expected was skipped | It is in `environmentExclude`, not in `environmentFilter`, or not Dataverse-linked | Check the Effective settings block and the environment list |
| More apps excluded than expected | A short `appExclude` value matched as a substring | Use the exact unique name or an explicit wildcard |
| `finopsversions returned HTTP 404 RouteNotFound` | The version route is not available on your endpoint | Expected today. Inventory still works. See section 6. |
| `Version apply skipped (LCSSandbox)` | LCS managed environment | By design. Update through Lifecycle Services. |
| F&O phase skipped with a PowerShell version warning | Running under Windows PowerShell 5.1 | Use `pwsh: true` in the task, or PowerShell 7 locally |
| `finopsproperties request failed before any HTTP response` | Transport failure (DNS, TLS, proxy, timeout) | Not an API error. Check agent network egress. |
| Unresolved `$(variable)` in the log | A variable referenced by the pipeline is missing from the group | Add it, or rely on the script default |
| A warning names `updateFinOpsVersion` or `finOpsInventory` | A retired variable is still in the group | Delete it. It has no effect either way. |
