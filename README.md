# d365-tenant-app-updater

Automatically update all Dynamics 365 first-party (Dataverse) apps across an entire tenant, from a single Azure DevOps pipeline.

> Community project. This is not an official Microsoft tool. Test it in a non-production tenant or environment before you point it at anything that matters.

---

## The goal

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Open the Power Platform Admin Center, pick an environment, open its Dynamics 365 apps, check each one for an update, install, wait, and then repeat for the next environment, and the next. Multiply that by every environment on the tenant and every first-party app, and app maintenance quietly eats hours you never get back.

This project turns that manual chore into a **hands-off, repeatable, tenant-wide** operation. A service principal authenticates non-interactively, the pipeline discovers every Dataverse environment on the tenant, compares the installed version of each app against the latest available version, and installs the updates that are genuinely newer. It can retry previously failed installs, protect specific environments, skip specific apps, and preview everything without changing a thing.

It scales the same whether you have 3 environments or 30, which is exactly where it saves the most time.

---

## How it works

The pipeline runs one PowerShell script that uses **three tokens** and **two data sources** to make a safe update decision per app:

```
Azure DevOps pipeline (azure-pipelines.yml)
        |
        v
  scripts/Update-TenantApps.ps1
        |
        |  1. Acquire tokens (service principal, client credentials):
        |       - BAP admin token       -> list environments + instanceUrl
        |       - Power Platform token  -> available app packages + install
        |       - Dataverse token       -> installed managed-solution versions
        |
        |  2. List every environment (BAP admin API) and keep only the ones
        |     that are Dataverse-linked (have an instanceUrl).
        |
        |  3. Apply environmentFilter (allow-list) and environmentExclude
        |     (deny-list) to decide which environments to process.
        |
        |  4. For each environment:
        |       a. AVAILABLE versions  <- Power Platform App Management API
        |          (/appmanagement/environments/{id}/applicationPackages)
        |       b. INSTALLED versions  <- Dataverse managed solutions
        |          ({instanceUrl}/api/data/v9.2/solutions, ismanaged eq true)
        |          The installed version of an app = the version of its
        |          (anchor) managed solution.
        |
        |  5. For each installed app:
        |       - skip if it is in appExclude
        |       - if state = InstallFailed and retry is on -> retry the install
        |       - else compare installed vs available; install ONLY when the
        |         available version is strictly newer (never downgrade)
        |
        |  6. Custom Install Experience apps (for example the F&O Provisioning
        |     App) are rejected by the API. They are reported as
        |     "manual-required" (never counted as failures), and can be
        |     pre-skipped via appExclude, or attempted via the PAC CLI fallback.
        |
        |  7. Print a per-environment and a tenant-wide summary.
        v
   Updated tenant
```

### Why installed versions come from Dataverse

The Power Platform App Management API tells you which apps exist and what the latest **available** version is, but it is not a reliable source for what is currently **installed**. The trustworthy source of the installed version is the app's **managed solution version** inside each environment's Dataverse. That is why the script reads `solutions` from Dataverse directly, and why the service principal needs an application-user role in each environment (see Requirements).

### Why it never downgrades

An app can legitimately be installed at a version newer than the catalog's currently-advertised version. A naive "installed not equal to available" check would try to reinstall/downgrade it. The script only acts when the available version is **strictly greater** than the installed version.

---

## Requirements (mandatory)

1. **Azure DevOps** organization and project, with permission to create a pipeline and a variable group.
2. **Entra ID (Azure AD) app registration** (service principal) with a **client secret**.
3. **Power Platform Administrator** rights in the tenant, used once to register the service principal as a management application (`New-PowerAppManagementApp`).
4. **Application user with a security role** (for example System Administrator) for the service principal in **each target environment's Dataverse** - this is what allows reading managed-solution versions and installing apps.
5. A **Windows agent** with **PowerShell 7** (the Microsoft-hosted `windows-latest` image is fine).
6. For the optional PAC CLI fallback only: a .NET SDK compatible with the CLI (recent versions target .NET 10). The pipeline installs the CLI for you when the fallback is enabled.

Full, step-by-step permission setup is in [docs/permissions.md](docs/permissions.md). It is the most common reason a fresh tenant fails, so read it before the first run.

---

## Configuration model: 3 required, everything else optional

This is the important part.

- **Only three variables are required:** `ClientId`, `ClientSecret`, `TenantId`.
- **Every other setting has a built-in default in the script.**
- To override any default, simply **add a variable with the matching name** to the `D365-TenantAppUpdater` variable group. If the variable is absent, the script uses its default. **No YAML editing is ever required to tune behavior.**

### Mandatory variables

| Variable | Secret | Description |
|---|---|---|
| `ClientId` | No | Entra ID application (client) id of the service principal. |
| `ClientSecret` | **Yes** | Client secret value. Always mark it as secret. |
| `TenantId` | No | Entra ID directory (tenant) id. |

### Optional variables (add only what you want to override)

All of these have sensible defaults. Add a variable with the exact name to override it.

| Variable | Default | What it does |
|---|---|---|
| `bapApiVersion` | `2026-06-01` | API version for the BAP environments list. |
| `appManagementApiVersion` | `2026-05-01-preview` | API version for the App Management calls. |
| `bapApiRoot` | `https://api.bap.microsoft.com` | BAP admin API base URL. |
| `ppApiRoot` | `https://api.powerplatform.com` | Power Platform App Management base URL. |
| `powerPlatformScope` | `https://api.powerplatform.com/.default` | Token scope for App Management. |
| `authority` | `https://login.microsoftonline.com/<TenantId>/oauth2/v2.0/token` | Token endpoint (built from `TenantId` if not set). |
| `pollIntervalSec` | `20` | Seconds between install completion polls. |
| `pollTimeoutMin` | `60` | Maximum minutes to wait for an install. |
| `dumpDiagnostics` | `true` | Print installed-vs-available diagnostics. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install failed. |
| `whatIf` | `false` | Plan only. Report what would change, install nothing. |
| `usePacFallback` | `false` | Attempt the PAC CLI for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | `msdyn_FinanceAndOperationsProvisioningApp` | Deny-list of app names/ids to always skip. |

`whatIf` and `usePacFallback` are also exposed as **runtime parameters** (queue-time dropdowns), so you can flip them for a single manual run without touching the variable group.

Full details and worked examples are in [docs/parameters.md](docs/parameters.md).

---

## Setup

Full walkthrough is in [docs/setup.md](docs/setup.md). In short:

1. Create the Entra ID app registration and a client secret.
2. Register the service principal as a Power Platform management application, and add it as an application user (System Administrator) in each target environment. See [docs/permissions.md](docs/permissions.md).
3. Create the `D365-TenantAppUpdater` variable group with the three required variables (plus any optional overrides you want).
4. Add the pipeline from `azure-pipelines.yml` and authorize it to use the variable group.
5. Run with `whatIf` set to `true` first to preview, then run for real.

---

## How to run

- **Manual:** run the pipeline and, if you like, flip the `whatIf` / `usePacFallback` dropdowns for that run.
- **First run:** set `whatIf` to `true` (dropdown or variable) so it reports the full installed-vs-available plan without installing anything.
- **Scheduled:** uncomment the `schedules` block in `azure-pipelines.yml` to keep the tenant continuously up to date.

---

## Environment and app scoping

- `environmentFilter` - allow-list. Only these environments are processed. Blank = all.
- `environmentExclude` - deny-list. Always skipped, even if they match the filter. Use it to protect production.
- `appExclude` - deny-list of apps always skipped (pre-seeded with the F&O Provisioning App, which requires the PPAC Custom Install Experience).

Worked examples for all three are in [docs/parameters.md](docs/parameters.md).

---

## Custom Install Experience apps

Some first-party apps (for example the Finance and Operations Provisioning App) use a guided wizard in the Power Platform Admin Center and cannot be installed by the API. The script detects the API's "not supported by this API" response and reports those apps as `manual-required` instead of failing the run. They can be pre-skipped via `appExclude`, or attempted best-effort via the PAC CLI fallback (`usePacFallback`).

---

## Known limitations and roadmap

- Targets Dynamics 365 first-party apps. It does not manage third-party or ISV solutions.
- Available versions depend on what the tenant's release channel exposes.
- The PAC CLI fallback uses the same programmability API family, so true Single Page Application install apps may still require the PPAC UI.
- Roadmap ideas: per-environment approval gates, Teams or email summary notification, parallel installs across environments, and a dry-run report artifact.

---

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

## Author

Laze Janev - Dynamics 365 Solution Architect and Microsoft MVP (AI ERP), founder of Janev Consulting.

- LinkedIn: https://www.linkedin.com/in/lazejanev/
- Microsoft MVP profile: https://mvp.microsoft.com/en-US/mvp/profile/5663c435-4e8a-4c28-8d49-7e76a6cfc4c4
- Speaker profile: https://sessionize.com/laze-janev/

If this saved you an afternoon, a star on the repo is appreciated, and I would love to hear how you use it.
