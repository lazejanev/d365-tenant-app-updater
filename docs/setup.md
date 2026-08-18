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

3. If your run installs apps into specific environments, also add the service principal as an application user with a suitable security role in each target environment's Dataverse.

## 3. Create the Azure DevOps variable group

The pipeline and script are fully variable driven. Everything lives in one Library variable group named `D365-TenantAppUpdater`.

1. In Azure DevOps, go to **Pipelines > Library > + Variable group**.
2. Name it exactly `D365-TenantAppUpdater` (or update the group name in `azure-pipelines.yml`).
3. Add every variable listed in [parameters.md](parameters.md): credentials, endpoints, behavior defaults, and the pipeline/agent values.
4. Mark `ClientSecret` as secret.
5. Save.

There are no hardcoded values in the YAML or the script, so the pipeline will not run until this group is complete.

## 4. Add the pipeline

1. Push this repository to your Git provider, or import it into Azure Repos.
2. In Azure DevOps, go to **Pipelines > New pipeline**.
3. Point it at your repository and select the existing `azure-pipelines.yml`.
4. Save (do not run yet).

## 5. Wire up the script endpoints

The two functions `Get-EnvironmentApps` and `Install-AppUpdate` in `scripts/Update-TenantApps.ps1` are stubs. Point them at the app inventory and install routes exposed to your tenant. Commented examples are included directly above each stub.

## 6. First run

1. Run the pipeline manually.
2. Leave **Plan only (do not install)** set to true for the first run so it reports without changing anything.
3. To be extra safe, set **Environment exclude** to your production environment name for the first runs.
4. Confirm the log shows:
   - `Acquired Power Platform and BAP tokens`
   - `Found N environment(s) on the tenant`
   - the effective settings block echoing your filter, exclude, and app exclude
   - a diagnostic table of installed versus available versions
5. When the plan looks right, run again with **Plan only** set to false to install the updates.

## 6a. Optional: the PAC CLI fallback

If you want the pipeline to attempt `pac application install` for custom-install apps:

1. Set the library variable `usePacFallback` to `true`, or pass the runtime parameter for a single run.
2. When the fallback is on, the pipeline automatically runs an "Install Power Platform CLI" step that installs the **`Microsoft.PowerApps.CLI.Tool`** .NET tool on the agent. You do not need to install it yourself.
3. **.NET 10 note.** Recent CLI tool versions (2.11.x) target **.NET 10.0**. Microsoft-hosted `windows-latest` agents generally have a compatible SDK. On a self-hosted agent, ensure .NET 10 is installed, or pin an older `pacCliVersion`.
4. **Pinning.** Set the `pacCliVersion` variable (for example `2.11.2`) for reproducible runs, or leave it blank to install the latest.

The fallback authenticates with the same service principal. It is best effort: for true Single Page Application install apps the CLI may still be blocked, in which case the app is reported as `manual-required`.

## 7. Schedule it (optional)

To keep the tenant continuously up to date, open `azure-pipelines.yml`, uncomment the `schedules` block, adjust the cron expression, and commit.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Forbidden` on the environments call | Service principal is not registered as a management app | Run `New-PowerAppManagementApp` (see permissions.md) |
| `invalid_client` on token acquisition | Wrong secret, expired secret, or wrong tenant | Recreate the secret and confirm `TenantId` |
| Token acquired but per-environment app call fails | Missing application user or role in that environment | Add the app user with a security role in Dataverse |
| An app shows as `manual-required` | It uses the PPAC Custom Install Experience | Install it in PPAC, or add it to `appExclude` |
| PAC fallback skipped with a warning | pac CLI not on the agent | Ensure `usePacFallback` is on so the install step runs, or install the CLI on a self-hosted agent |
| An environment you expected was skipped | It is in `environmentExclude`, or not in `environmentFilter` | Check the effective settings block in the log |
| Empty environment list | Filter too narrow, or SP has no admin visibility | Clear `environmentFilter`, confirm management app registration |
