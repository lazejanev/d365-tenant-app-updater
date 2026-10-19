# Permissions

This is the most important document in the repository. On a fresh tenant, the pipeline authenticates successfully and then fails with `Forbidden`, or reads zero installed versions. That is almost always because the service principal is not yet authorized at one of three layers. Getting a token is not the same as being allowed to call the admin APIs or read Dataverse.

## The three layers you must satisfy

1. **Entra ID app registration with a valid secret or federated credential.** (Authentication)
2. **Registration as a Power Platform management application.** (Tenant-level admin authorization - lets the service principal list environments via the BAP admin API and call the Power Platform APIs.)
3. **Application user with a security role in each target environment.** (Environment-level authorization - lets the service principal read managed-solution versions from Dataverse and install apps.)

Miss any one and the run fails at a predictable point.

In short, for the setup this project was verified against:

| What | Who does it | Where |
|---|---|---|
| App registration with a secret or federated credential. No Microsoft Graph or Dynamics API permissions, and no F&O-specific API permission | Anyone who can register apps | Microsoft Entra ID |
| Register it as a Power Platform management app (`New-PowerAppManagementApp`) | A Power Platform Administrator (or Global Administrator) | Once per tenant |
| Add it as an application user with **System Administrator** | A System Administrator of that environment | Each target environment |

## 1. App registration: secret or federated credential

- Create the app registration (see [setup-azure-devops.md](setup-azure-devops.md) or [setup-github.md](setup-github.md)).
- Then either:
  - **Client secret.** Confirm it is not expired. An expired or missing secret produces `AADSTS7000218` or `invalid_client` at token time.
  - **Federated credential (no secret, v3).** Add one per trust under **Certificates & secrets > Federated credentials**: the GitHub repository (branch and environment), or the Azure DevOps service connection. A mismatch produces `AADSTS70021: No matching federated identity record found`. Federated credentials sign in as the same app, so layers 2 and 3 below are unchanged.

## 2. Register as a Power Platform management application

This authorizes an app-only service principal to call the BAP admin routes such as `scopes/admin/environments`. Without it, the environments call returns:

```
"code": "Forbidden",
"message": "The service principal ... does not have permission to access the path
.../scopes/admin/environments ... in tenant ...".
```

A Power Platform Administrator or Global Administrator runs this once:

```powershell
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser
Add-PowerAppsAccount
New-PowerAppManagementApp -ApplicationId <application-client-id>
```

Verify it registered:

```powershell
Get-PowerAppManagementApp -ApplicationId <application-client-id>
```

**This step is what grants access to the admin APIs.** In the configuration this project was verified against, it was sufficient on its own: no additional API permissions were added to the app registration, and both the App Management calls and the Finance and Operations routes succeeded with the resulting app-only token.

If your tenant is configured more restrictively and you see `Forbidden` (not `RouteNotFound`) on a Power Platform API call after completing this step, add the Power Platform API permission your tenant requires to the app registration and grant admin consent. The exact permission depends on your tenant's configuration, so check the error body: it names the path that was refused.

## 3. Application user per environment (required)

The script reads the **installed** version of each app from Dataverse managed solutions, and installs apps into the environment. Both require the service principal to be an application user in **each target environment**:

- Power Platform Admin Center > select the environment.
- **Settings > Users + permissions > Application users > New app user**.
- Add the app using its Application (client) ID.
- Choose the business unit, then assign a security role that permits reading solutions and managing apps, for example **System Administrator**.
- Click **Create**.

Adding an application user needs a System Administrator of that environment.

Repeat for every environment you want the pipeline to manage. This is separate from the tenant-level management app registration in step 2. Skipping it produces the warning `<env>: could not read installed solutions, apps skipped (nothing is installed blindly)` in the log, and "solutions unavailable" in the environments table. The script safely skips that environment's apps rather than installing blindly.

Add the app user to any newly created environment as well, or that environment will simply be skipped.

## Finance and Operations routes

The Finance and Operations routes under `/dynamics/environments/{id}/` use the same Power Platform token as the App Management calls. No additional scope or separate registration is required.

This has been verified in practice: with an app-only (client credentials) token, `finopsproperties` returns HTTP 200 with full environment data, using the identical token that also succeeds against App Management.

- If a Finance and Operations route returns **403 Forbidden**, revisit steps 2 and 3 above.
- If `finopsversions` returns **404 RouteNotFound** while `finopsproperties` succeeds on the same environment, same token, same api-version, this is **not** a permissions problem. It has been observed to be intermittent: the identical call on the identical environment can return RouteNotFound on one run and a genuine 200 with real version data on a later run, with no configuration change in between. Treat it as a normal platform condition and simply re-run. See the Finance and Operations section of the [README](../README.md).

## Outbound network access (Finance and Operations release map)

At the start of the Finance and Operations phase the agent downloads Microsoft's PQU release schedule (a public, read-only file, no credentials) from `raw.githubusercontent.com` to work out which release each environment is on. Microsoft-hosted agents have this access. On a self-hosted agent behind a firewall, allow outbound HTTPS to `raw.githubusercontent.com`. Without it the run still works: the log shows a warning and the built-in release map (10.0.46 to 10.0.49) is used, so environments on newer releases are skipped rather than guessed.

## PowerShell version

v3 requires **PowerShell 7.2 or later** for the whole run. The Azure DevOps pipelines use `pwsh` and GitHub runners have it preinstalled. Windows PowerShell 5.1 is no longer supported.

## Failure map

| Where it fails | Missing layer | Fix |
|---|---|---|
| Token acquisition (`invalid_client`, `AADSTS7000218`) | Layer 1 | Recreate the secret, confirm tenant id |
| `Forbidden` on `scopes/admin/environments` | Layer 2 | `New-PowerAppManagementApp` |
| "could not read installed solutions, apps skipped" for an environment | Layer 3 | Add the application user with a role in that environment |
| 403 on a Finance and Operations route | Layer 2 or 3 | Re-check the management app registration, then the app user |
| 404 `RouteNotFound` on `finopsversions`, while `finopsproperties` succeeds | Not a permissions issue | Intermittent platform behaviour. Re-run. |
| `AADSTS70021` (federated sign-in) | Layer 1 | The federated credential's issuer, subject or audience does not match. See the setup guide |
| "requires PowerShell 7.2" | Not a permissions issue | Run with `pwsh` 7.2 or later |

## Least privilege note

System Administrator is the simplest role to get running. For production, prefer a custom security role scoped to only the solution-read and app-management operations this pipeline performs, and document it so reviewers understand what the service principal can and cannot do.
