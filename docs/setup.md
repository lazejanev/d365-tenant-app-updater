# Setup

This guide takes you from nothing to a working pipeline. It has three parts: the service principal, the Azure DevOps configuration, and the first run.

Read [permissions.md](permissions.md) alongside this guide. The permissions step is the most common reason a fresh tenant fails.

## 1. Create the service principal

1. In the Microsoft Entra admin center, go to **Entra ID > App registrations > New registration**.
2. Give it a clear name, for example `d365-tenant-app-updater`.
3. Leave the redirect URI empty. This is an app-only (client credentials) flow.
4. Register the app.
5. Note the **Application (client) ID** and the **Directory (tenant) ID**.
6. Go to **Certificates & secrets > New client secret**, create one, and copy the value now. You cannot read it again later.

## 2. Grant permissions and register as a management app

Follow [permissions.md](permissions.md). In short:

1. Add the required API permission to the app registration and grant admin consent.
2. Register the service principal as a Power Platform management application:

   ```powershell
   Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
   Add-PowerAppsAccount
   New-PowerAppManagementApp -ApplicationId <application-client-id>
   ```

3. Add the service principal as an **application user with a security role** (for example System Administrator) in **each target environment's Dataverse**. This is required to read managed-solution versions and to install apps.

## 3. Create the Azure DevOps variable group

The pipeline needs only three variables to run. Everything else has a built-in default and is optional.

1. In Azure DevOps, go to **Pipelines > Library > + Variable group**.
2. Name it exactly `D365-TenantAppUpdater` (or update the group name in `azure-pipelines.yml`).
3. Add the three required variables:

   | Name | Value | Secret |
   |---|---|---|
   | `ClientId` | Application (client) ID | No |
   | `ClientSecret` | The client secret value | **Yes** |
   | `TenantId` | Directory (tenant) ID | No |

4. Optionally add any override variables you want (see [parameters.md](parameters.md)). For example, many teams add:
   - `environmentExclude` = `Production` (protect production)
   - `appExclude` = `msdyn_FinanceAndOperationsProvisioningApp` (already the default)
5. Save.

> There is no `pipelineName`, `agentVmImage`, or endpoint variable to set. The run name and agent image are fixed in the YAML, and all API endpoints/versions are script defaults you can override only if you ever need to.

## 4. Add the pipeline

1. Push this repository to your Git provider, or import it into Azure Repos.
2. In Azure DevOps, go to **Pipelines > New pipeline**.
3. Point it at your repository and select the existing `azure-pipelines.yml`.
4. Save (do not run yet).
5. Authorize the pipeline to use the variable group: open the variable group > **Pipeline permissions** > add this pipeline. (You can also authorize on first run when prompted.)

## 5. First run (preview)

1. Run the pipeline manually.
2. Set the **Plan only (do not install)** dropdown to `true` (or add a `whatIf = true` variable) so the first run reports without changing anything.
3. To be extra safe, set `environmentExclude` to your production environment name for the first runs.
4. Confirm the log shows:
   - the **Effective settings** block (verify the API versions, filter, exclude, appExclude)
   - `Acquired Power Platform and BAP tokens`
   - `Found N Dataverse environment(s)`
   - per-environment `installed vs available` diagnostics
   - a **TENANT SUMMARY** at the end
5. When the plan looks right, run again with **Plan only** set to `false` to install the updates.

## 6. Optional: enable the PAC CLI fallback

If you want the pipeline to attempt `pac application install` for custom-install apps:

1. Set the **Try PAC CLI fallback** dropdown to `true`, or add a `usePacFallback = true` variable.
2. When the fallback is on, the pipeline automatically runs an "Install Power Platform CLI" step that installs the `Microsoft.PowerApps.CLI.Tool` .NET tool on the agent.
3. Recent CLI versions target .NET 10; the hosted `windows-latest` image generally has a compatible SDK.

The fallback authenticates with the same service principal. It is best effort: for true Single Page Application install apps the CLI may still be blocked, in which case the app is reported as `manual-required`.

## 7. Schedule it (optional)

To keep the tenant continuously up to date, open `azure-pipelines.yml`, uncomment the `schedules` block, adjust the cron expression, and commit.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Job fails before any step; `$(agentVmImage)` shown literally | (Legacy) not applicable now - the image is fixed in YAML | Ensure you are on the current `azure-pipelines.yml` |
| `Forbidden` on the environments call | Service principal is not registered as a management app | Run `New-PowerAppManagementApp` (see permissions.md) |
| `invalid_client` / `AADSTS7000218` on token | Wrong secret, expired secret, or wrong tenant | Recreate the secret and confirm `TenantId` |
| `Failed to read Dataverse solution versions` | Missing application user or role in that environment | Add the app user with a security role in Dataverse |
| An app shows as `manual-required` | It uses the PPAC Custom Install Experience | Install it in PPAC, or add it to `appExclude` |
| `InvalidApiVersion` on the environments call | An override set `bapApiVersion` to an unsupported value | Remove the override (use the default) or set a supported version |
| An environment you expected was skipped | It is in `environmentExclude`, or not in `environmentFilter`, or not Dataverse-linked | Check the Effective settings block and the environment list |
