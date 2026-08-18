# Permissions

This is the most important document in the repository. On a fresh tenant, the pipeline authenticates successfully and then fails with `Forbidden`, or reads zero installed versions. That is almost always because the service principal is not yet authorized at one of three layers. Getting a token is not the same as being allowed to call the admin APIs or read Dataverse.

## The three layers you must satisfy

1. **Entra ID app registration with a valid secret.** (Authentication)
2. **Registration as a Power Platform management application.** (Tenant-level admin authorization - lets the SP list environments via the BAP admin API and call App Management.)
3. **Application user with a security role in each target environment.** (Environment-level authorization - lets the SP read managed-solution versions from Dataverse and install apps.)

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

On the app registration, add the Power Platform API permission that matches the App Management calls, then grant admin consent.

## 4. Application user per environment (required)

The script reads the **installed** version of each app from Dataverse managed solutions, and installs apps into the environment. Both require the service principal to be an application user in **each target environment**:

1. Power Platform Admin Center > select the environment.
2. **Settings > Users + permissions > Application users > New app user**.
3. Add the app using its Application (client) ID.
4. Assign a security role that permits reading solutions and managing apps, for example **System Administrator**, or a least-privilege custom role that covers those operations.

Repeat for every environment you want the pipeline to update. This is separate from the tenant-level management app registration in step 2. Skipping it produces `Failed to read Dataverse solution versions for '<env>'`, and the script safely skips that environment rather than installing blindly.

## Failure map

| Where it fails | Missing layer | Fix |
|---|---|---|
| Token acquisition (`invalid_client`, `AADSTS7000218`) | Layer 1 | Recreate the secret, confirm tenant id |
| `Forbidden` on `scopes/admin/environments` | Layer 2 | `New-PowerAppManagementApp` |
| `Failed to read Dataverse solution versions` for an environment | Layer 3 | Add the application user with a role in that environment |
| `403` after an admin consent change | Consent not propagated | Re-grant admin consent, wait, retry |

## Least privilege note
System Administrator is the simplest role to get running. For production, prefer a custom security role scoped to only the solution-read and app-management operations this pipeline performs, and document it so reviewers understand what the service principal can and cannot do.
