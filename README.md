# d365-tenant-app-updater

**Automatically update all Dynamics 365 first-party (Dataverse) apps across an entire tenant, and report Finance and Operations environment inventory, from a single Azure DevOps pipeline.**

![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f) ![Version 2.2.0](https://img.shields.io/badge/version-2.2.0-1e90ff) ![PRs welcome](https://img.shields.io/badge/PRs-welcome-0b3d91) ![Community project](https://img.shields.io/badge/status-community%20project-111827)

![D365 F&O](https://img.shields.io/badge/Dynamics%20365%20F%26O-002050?logo=microsoftdynamics365&logoColor=white) ![Power Platform](https://img.shields.io/badge/Power%20Platform-742774?logo=microsoftpowerplatform&logoColor=white) ![Dataverse](https://img.shields.io/badge/Dataverse-0067B8?logo=microsoft&logoColor=white) ![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D7?logo=azuredevops&logoColor=white) ![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)

**Contents:** [Goal](#the-goal) | [How it works](#how-it-works) | [Requirements](#requirements-mandatory) | [Configuration](#configuration-model-3-required-everything-else-optional) | [Setup](#setup) | [Finance and Operations](#finance-and-operations) | [Pipelines](#pipelines-in-this-repo) | [Parameters](docs/parameters.md)

> **Note**
> Community project. This is not an official Microsoft tool. Test it in a non-production tenant or environment before you point it at anything that matters.

---

## The goal

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Open the Power Platform Admin Center, pick an environment, open its Dynamics 365 apps, check each one for an update, install, wait, and then repeat for the next environment, and the next. Multiply that by every environment on the tenant and every first-party app, and app maintenance quietly eats hours you never get back.

This project turns that manual chore into a hands-off, repeatable, tenant-wide operation. A service principal authenticates non-interactively, the pipeline discovers every Dataverse environment on the tenant, compares the installed version of each app against the latest available version, and installs the updates that are genuinely newer. It can retry previously failed installs, protect specific environments, skip specific apps, and preview everything without changing a thing.

It also reports a **Finance and Operations inventory** across the tenant: application version, platform version, deployment type and AOS counts for every F&O environment, which makes version drift obvious at a glance.

It scales the same whether you have 3 environments or 30, which is exactly where it saves the most time.

---

## How it works

One PowerShell script, two phases, three tokens.

```text
Azure DevOps pipeline (azure-pipelines.yml)
        |
        v
  scripts/Update-TenantApps.ps1
        |
        |  Acquire tokens (service principal, client credentials):
        |    - BAP admin token      -> list environments + instanceUrl
        |    - Power Platform token -> app packages, install, F&O routes
        |    - Dataverse token      -> installed managed-solution versions
        |
   ===== PHASE 1 - application updates (always runs) =====
        |  1. List every environment and keep the Dataverse-linked ones.
        |  2. Apply environmentFilter (allow-list) and environmentExclude
        |     (deny-list).
        |  3. Per environment:
        |       AVAILABLE  <- /appmanagement/environments/{id}/applicationPackages
        |       INSTALLED  <- {instanceUrl}/api/data/v9.2/solutions (ismanaged eq true)
        |     The installed version of an app is the version of its anchor
        |     managed solution.
        |  4. Per app: skip if in appExclude; retry if state = InstallFailed;
        |     otherwise install ONLY when available is strictly newer.
        |  5. Apps that require the PPAC Custom Install Experience are
        |     reported as "manual install required", never as failures.
        |  6. While doing the above, record which environments have Finance
        |     and Operations installed. No extra API calls.
        |
   ===== PHASE 2 - Finance and Operations (opt-in) =====
        |  7. For each F&O environment:
        |       INVENTORY <- /dynamics/environments/{id}/finopsproperties
        |       VERSIONS  <- /dynamics/environments/{id}/finopsversions
        |       APPLY     -> POST .../finopsversions/{version}/apply
        |     LCS managed environments are inventoried but never
        |     version-updated. See the Finance and Operations section.
        v
   Updated tenant + F&O inventory
```

**Why installed versions come from Dataverse.** The App Management API tells you which apps exist and the latest **available** version, but it is not a reliable source for what is currently **installed**. The trustworthy source is the app's **managed solution version** inside each environment's Dataverse. That is why the service principal needs an application-user role in every environment.

**Why it never downgrades.** An app can legitimately be installed at a version newer than the catalog's advertised version. The script only acts when available is **strictly greater** than installed.

---

## Requirements (mandatory)

1. **Azure DevOps** organization and project, with permission to create a pipeline and a variable group.
2. **Entra ID (Azure AD) app registration** (service principal) with a **client secret**.
3. **Power Platform Administrator** rights, used once to register the service principal as a management application (`New-PowerAppManagementApp`).
4. **Application user with a security role** (for example System Administrator) for the service principal in **each target environment's Dataverse**.
5. A **Windows agent** with **PowerShell 7** (the Microsoft-hosted `windows-latest` image is fine).
6. For the optional PAC CLI fallback only: a .NET SDK compatible with the CLI. The pipeline installs the CLI when the fallback is enabled.

Full permission setup is in [docs/permissions.md](docs/permissions.md). It is the most common reason a fresh tenant fails, so read it before the first run.

---

## Configuration model: 3 required, everything else optional

- **Only three variables are required:** `ClientId`, `ClientSecret`, `TenantId`.
- **Every other setting has a built-in default in the script.**
- To override a default, **add a variable with the matching name** to the `D365-TenantAppUpdater` variable group. If it is absent, the default applies. **No YAML editing is ever required.**

### Mandatory variables

| Variable | Secret | Description |
|---|---|---|
| `ClientId` | No | Entra ID application (client) id of the service principal. |
| `ClientSecret` | **Yes** | Client secret value. Always mark it as secret. |
| `TenantId` | No | Entra ID directory (tenant) id. |

### Optional variables (add only what you want to override)

| Variable | Default | What it does |
|---|---|---|
| `bapApiVersion` | `2026-06-01` | API version for the BAP environments list. |
| `appManagementApiVersion` | `2026-05-01-preview` | API version for App Management calls. |
| `finOpsApiVersion` | `2024-10-01` | API version for the Finance and Operations routes. |
| `bapApiRoot` | `https://api.bap.microsoft.com` | BAP admin API base URL. |
| `ppApiRoot` | `https://api.powerplatform.com` | Power Platform API base URL. |
| `powerPlatformScope` | `https://api.powerplatform.com/.default` | Token scope for Power Platform. |
| `authority` | built from `TenantId` | Token endpoint. |
| `pollIntervalSec` | `20` | Seconds between install completion polls. |
| `pollTimeoutMin` | `60` | Maximum minutes to wait for an install. |
| `dumpDiagnostics` | `true` | Print installed-vs-available diagnostics. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install failed. |
| `whatIf` | `false` | Plan only. Report what would change, change nothing. |
| `usePacFallback` | `false` | Attempt the PAC CLI for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids. |
| `appExclude` | (blank) | Deny-list of app names/ids to always skip. |
| `updateFinOpsVersion` | `false` | Enable the Finance and Operations phase. |
| `finOpsTargetVersion` | (blank = latest) | Specific F&O version to apply. |
| `finOpsEnvironmentFilter` | (blank = all detected) | Extra allow-list for the F&O phase only. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a version apply. |

`whatIf`, `usePacFallback`, `updateFinOpsVersion` and `finOpsTargetVersion` are also exposed as **runtime parameters**, so you can override them for a single manual run.

Full details and worked examples are in [docs/parameters.md](docs/parameters.md).

---

## Setup

Full walkthrough is in [docs/setup.md](docs/setup.md). In short:

1. Create the Entra ID app registration and a client secret.
2. Register the service principal as a Power Platform management application, and add it as an application user (System Administrator) in each target environment. See [docs/permissions.md](docs/permissions.md).
3. Create the `D365-TenantAppUpdater` variable group with the three required variables.
4. Add the pipeline from `azure-pipelines.yml` and authorize it to use the variable group.
5. Run with `whatIf` set to `true` first to preview, then run for real.

---

## Finance and Operations

The F&O phase is **off by default**. Set `updateFinOpsVersion` to `true` to enable it.

Detection is free: while Phase 1 is already reading each environment's application packages, it records which environments have Finance and Operations installed. Only packages whose state is `Installed` or `InstallFailed` count, so environments that are merely *offered* an F&O package are not misidentified.

### Inventory (works today)

For every detected F&O environment the pipeline reports:

- Application version and platform version
- Deployment type (`UnifiedDeveloper`, `UnifiedSandbox`, `UnifiedProduction`, `LCSSandbox`, `LCSProduction`)
- AOS counts, interactive and batch, observed against maximum
- Demo dataset and any scheduled actions

It then prints a consolidated table so version drift across the estate is obvious:

```text
Environment       Application   Platform     Deployment       AOS   Note
-----------       -----------   --------     ----------       ---   ----
commerce-code-ppr 10.0.2645.124 7.0.7996.111 LCSSandbox       2 / 2 version apply skipped (LCSSandbox)
TPM-DEV01         10.0.2645.124 7.0.7996.111 UnifiedDeveloper 1 / 1 versions: RouteNotFound
TPM-DEV02         10.0.2645.136 7.0.7996.119 UnifiedDeveloper 1 / 1 versions: RouteNotFound
COMMERCE-CODE     10.0.2790.46  7.0.8199.32  UnifiedSandbox   1 / 9 versions: RouteNotFound
```

### LCS managed environments are never version-updated

`LCSSandbox` and `LCSProduction` environments are **inventoried but deliberately excluded from version apply**, because their application updates are driven through Lifecycle Services rather than the Power Platform API. This is controlled by `finOpsDeploymentTypes`, which defaults to the Unified types only.

### Known limitation: the version routes

Version discovery and apply are implemented against the documented Power Platform API:

```text
GET  {ppApiRoot}/dynamics/environments/{environmentId}/finopsversions?api-version=2024-10-01
POST {ppApiRoot}/dynamics/environments/{environmentId}/finopsversions/{version}/apply?api-version=2024-10-01
```

At the time of writing, on a tenant in West Europe using an app-only (client credentials) token, the observed behaviour is:

| Route | Result |
|---|---|
| `finopsproperties` | **HTTP 200** with full data |
| `finopsversions` | HTTP 404 `RouteNotFound` |

Because `finopsproperties` succeeds on the identical call shape, the token, the environment id and the api-version are all accepted. The `finopsversions` leaf simply does not resolve on that endpoint. This was observed consistently across 11 environments spanning two deployment types.

**What this means in practice:**

- **Inventory works.** That is the useful capability available today.
- **Version apply does not run** while the route returns `RouteNotFound`. It is reported factually per environment and is **not** counted as a failure.
- **No code change will be needed.** The apply logic is implemented and gated behind a live route check. When the route becomes available on your endpoint, the next run starts using it automatically. You will see the `Note` column change from `versions: RouteNotFound` to real version numbers.

---

## How to run

- **Manual:** run the pipeline and, if you like, flip the runtime parameters for that run.
- **First run:** set `whatIf` to `true` so it reports without changing anything.
- **Scheduled:** uncomment the `schedules` block in `azure-pipelines.yml`.

---

## Pipelines in this repo

### 1. `azure-pipelines.yml` - the tenant app updater

The main pipeline. Runs `scripts/Update-TenantApps.ps1` to update Dynamics 365 first-party apps across every Dataverse environment, and optionally report F&O inventory.

### 2. `sync-from-github.yml` - GitHub to Azure DevOps sync

Optional. Keeps an Azure DevOps mirror of this repository in step with GitHub, so teams that build from Azure DevOps Repos never work from a stale copy.

- Runs on a schedule only. Default cron is hourly with `always: true`.
- Fetches `main` plus tags from the GitHub remote.
- Sync strategy: `reset` (mirror, force-resets the branch) or `ff-only` (safe, fails if histories diverged).
- Pushes using `System.AccessToken`.

One-time Azure DevOps setup, **per project** (repository permissions do not carry across projects):

1. **Project Settings > Repositories > (repo) > Security:** grant the build service **Contribute**. For the default `reset` strategy also grant **Force push**.
2. If `main` has a branch policy, add the build service as an exception.

---

## Environment and app scoping

| Control | Type | Effect |
|---|---|---|
| `environmentFilter` | allow-list | Only these environments are processed. Blank means all. |
| `environmentExclude` | deny-list | Always skipped, even if they match the filter. Use it to protect production. |
| `appExclude` | deny-list | Apps always skipped. Matches exact, wildcard, or substring. |
| `finOpsEnvironmentFilter` | allow-list | Extra restriction applied to the F&O phase only. |
| `finOpsDeploymentTypes` | allow-list | Deployment types eligible for an F&O version apply. |

Worked examples are in [docs/parameters.md](docs/parameters.md).

---

## Custom Install Experience apps

Some first-party apps, notably the Finance and Operations Provisioning App, use a guided wizard in the Power Platform Admin Center and cannot be installed by the API. The script detects the API's "Custom Install Experience" response and reports those apps as **manual install required** in a summary table rather than failing the run. Add them to `appExclude` if you prefer to silence them entirely.

---

## Known limitations and roadmap

- Targets Dynamics 365 first-party apps. It does not manage third-party or ISV solutions.
- Available versions depend on what the tenant's release channel exposes.
- F&O version apply depends on the `finopsversions` route being available on your endpoint. See [Finance and Operations](#finance-and-operations).
- LCS managed environments are inventoried only, by design.
- Roadmap ideas: per-environment approval gates, Teams or email summary notification, parallel installs, and a dry-run report artifact.

---

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

---

## Author

**Laze Janev** - Dynamics 365 Solution Architect and Microsoft MVP (AI ERP), founder of Janev Consulting.

- LinkedIn: https://www.linkedin.com/in/lazejanev/
- Microsoft MVP profile: https://mvp.microsoft.com/en-US/mvp/profile/5663c435-4e8a-4c28-8d49-7e76a6cfc4c4
- Speaker profile: https://sessionize.com/laze-janev/

If this saved you an afternoon, a star on the repo is appreciated, and I would love to hear how you use it.
