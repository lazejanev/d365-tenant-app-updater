# Permissions

This is the most important document in the repository. On a fresh tenant, the pipeline authenticates successfully and then fails with `Forbidden`, or reads zero installed versions. That is almost always because the service principal is not yet authorized at one of three layers. Getting a token is not the same as being allowed to call the admin APIs or read Dataverse.

## The three layers you must satisfy

1. **Entra ID app registration with a valid secret.** (Authentication)
2. **Registration as a Power Platform management application.** (Tenant-level admin authorization - lets the service principal list environments via the BAP admin API and call the Power Platform APIs.)
3. **Application user with a security role in each target environment.** (Environment-level authorization - lets the service principal read managed-solution versions from Dataverse and install apps.)

Miss any one and the run fails at a predictable point.

## 1. App registration and secret

- Create the app registration and a client secret (see setup.md).
- Confirm the secret is not expired. An expired or missing secret produces `AADSTS7000218` or `invalid_client` at token time.

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

## 3. API permissions and admin consent

On the app registration, add the Power Platform API permission that matches the App Management and Finance and Operations calls, then grant admin consent.

## 4. Application user per environment (required)

The script reads the **installed** version of each app from Dataverse managed solutions, and installs apps into the environment. Both require the service principal to be an application user in **each target environment**:

1. Power Platform Admin Center > select the environment.
2. **Settings > Users + permissions > Application users > New app user**.
3. Add the app using its Application (client) ID.
4. Choose the business unit, then assign a security role that permits reading solutions and managing apps, for example **System Administrator**.
5. Click **Create**.

Repeat for every environment you want the pipeline to manage. This is separate from the tenant-level management app registration in step 2. Skipping it produces `Failed to read Dataverse solution versions for '<env>'`, and the script safely skips that environment rather than installing blindly.

Add the app user to any newly created environment as well, or that environment will simply be skipped.

## Finance and Operations routes

The Finance and Operations routes under `/dynamics/environments/{id}/` use the same Power Platform token as the App Management calls. No additional scope or separate registration is required.

This has been verified in practice: with an app-only (client credentials) token, `finopsproperties` returns HTTP 200 with full environment data. If a Finance and Operations route returns `403 Forbidden`, revisit layers 2 and 3 above. If it returns `404 RouteNotFound` while `finopsproperties` succeeds, that is a route availability issue on the endpoint rather than a permissions problem. See the Finance and Operations section of the README.

## Failure map

| Where it fails | Missing layer | Fix |
|---|---|---|
| Token acquisition (`invalid_client`, `AADSTS7000218`) | Layer 1 | Recreate the secret, confirm tenant id |
| `Forbidden` on `scopes/admin/environments` | Layer 2 | `New-PowerAppManagementApp` |
| `Failed to read Dataverse solution versions` for an environment | Layer 3 | Add the application user with a role in that environment |
| `403` on a Finance and Operations route | Layer 2 or 3 | Re-check the management app registration and admin consent |
| `404 RouteNotFound` on `finopsversions` only | Not a permissions issue | Route availability. See the README. |
| `403` after an admin consent change | Consent not propagated | Re-grant admin consent, wait, retry |

## Least privilege note

System Administrator is the simplest role to get running. For production, prefer a custom security role scoped to only the solution-read and app-management operations this pipeline performs, and document it so reviewers understand what the service principal can and cannot do.
