# d365-tenant-app-updater

**Automatically update all Dynamics 365 first-party (Dataverse) apps across an entire tenant, and report Finance and Operations environment inventory, from a single Azure DevOps pipeline.**

![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)
![Version 2.4.1](https://img.shields.io/badge/version-2.4.1-1e90ff)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-0b3d91)
![Community project](https://img.shields.io/badge/status-community%20project-111827)

![D365 F&O](https://img.shields.io/badge/Dynamics%20365%20F%26O-002050?logo=microsoftdynamics365&logoColor=white)
![Power Platform](https://img.shields.io/badge/Power%20Platform-742774?logo=microsoftpowerplatform&logoColor=white)
![Dataverse](https://img.shields.io/badge/Dataverse-0067B8?logo=microsoft&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D7?logo=azuredevops&logoColor=white)
![PowerShell](https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white)

**Contents:** [Goal](#the-goal) | [How it works](#how-it-works) | [Requirements](#requirements-mandatory) | [Configuration](#configuration-model-3-required-everything-else-optional) | [Setup](#setup) | [Finance and Operations](#finance-and-operations) | [Pipelines](#pipelines-in-this-repo) | [Parameters](docs/parameters.md)

> **Note**
> Community project. This is not an official Microsoft tool. Test it in a non-production tenant or environment before you point it at anything that matters.

## The goal

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Open the Power Platform Admin Center, pick an environment, open its Dynamics 365 apps, check each one for an update, install, wait, and then repeat for the next environment, and the next. Multiply that by every environment on the tenant and every first-party app, and app maintenance quietly eats hours you never get back.

This project turns that manual chore into a hands-off, repeatable, tenant-wide operation. A service principal authenticates non-interactively, the pipeline discovers every Dataverse environment on the tenant, compares the installed version of each app against the latest available version, and installs the updates that are genuinely newer. It can retry previously failed installs, protect specific environments, skip specific apps, and preview everything without changing a thing.

It also reports a **Finance and Operations inventory** across the tenant, and can optionally apply F&O application version updates, distinguishing between a same-train quality update and a move to a new release train.

It scales the same whether you have 3 environments or 30, which is exactly where it saves the most time.

## How it works

One PowerShell script, two phases, three tokens.

```
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
        |  5. The F&O Provisioning App Anchor Solution is excluded here -
        |     it always fails with Custom Install Experience, and is
        |     exclusively owned by Phase 2's dedicated route.
        |
   ===== PHASE 2 - Finance and Operations =====
        |  6. INVENTORY (always runs, read-only, no switch):
        |       <- /dynamics/environments/{id}/finopsproperties
        |     Reports the LIVE application version, fetched fresh every run.
        |  7. VERSION APPLY (finOpsApplyVersion, default OFF - the only
        |     on/off switch that exists):
        |       VERSIONS <- /dynamics/environments/{id}/finopsversions
        |       APPLY    -> POST .../finopsversions/{version}/apply
        |     finOpsUpdateScope selects WHICH kind of version is eligible,
        |     matched against Microsoft's OWN releaseStage on each entry.
        |     LCS managed environments are inventoried but never
        |     version-updated.
        v
   Updated tenant + F&O inventory
```

**Why installed versions come from Dataverse.** The App Management API tells you which apps exist and the latest **available** version, but it is not a reliable source for what is currently **installed**. The trustworthy source is the app's **managed solution version** inside each environment's Dataverse. That is why the service principal needs an application-user role in every environment.

**Why it never downgrades.** An app can legitimately be installed at a version newer than the catalog's advertised version. The script only acts when available is **strictly greater** than installed.

## Requirements (mandatory)

- **Azure DevOps** organization and project, with permission to create a pipeline and a variable group.
- **Entra ID (Azure AD) app registration** (service principal) with a **client secret**.
- **Power Platform Administrator** rights, used once to register the service principal as a management application (`New-PowerAppManagementApp`).
- **Application user with a security role** (for example System Administrator) for the service principal in **each target environment's Dataverse**.
- A **Windows agent** with **PowerShell 7** (the Microsoft-hosted `windows-latest` image is fine). The Finance and Operations phase requires PowerShell 7 specifically; on 5.1 it is skipped with a clear message and Phase 1 still runs.
- For the optional PAC CLI fallback only: a .NET SDK compatible with the CLI. The pipeline installs the CLI when the fallback is enabled.

Full permission setup is in [docs/permissions.md](docs/permissions.md). It is the most common reason a fresh tenant fails, so read it before the first run.

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
| `dumpDiagnostics` | `true` | Print per-environment diagnostic detail. |
| `dumpSolutionCatalog` | `false` | Dump the full Dataverse managed-solution catalog (separate from `dumpDiagnostics`; can be 150+ lines). |
| `retryFailedInstalls` | `true` | Retry apps whose previous install failed. |
| `whatIf` | `false` | Plan only. Report what would change, change nothing. |
| `usePacFallback` | `false` | Attempt the PAC CLI for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids. |
| `appExclude` | (blank) | Deny-list of app names/ids to always skip. |
| `finOpsApplyVersion` | `false` | **The only Finance and Operations on/off switch.** Changes environments when true. |
| `finOpsUpdateScope` | `QualityUpdate` | Which kind of version apply may select: `QualityUpdate` (PQU, same-train patch), `VersionUpdate` (new release train), or `Any`. Matched against Microsoft's own `releaseStage`. |
| `finOpsTargetVersion` | (blank = highest matching scope) | Specific F&O version to apply. |
| `finOpsEnvironmentFilter` | (blank = all detected) | Extra allow-list for the F&O apply phase only. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a version apply. |

`whatIf`, `usePacFallback`, `finOpsApplyVersion`, `finOpsUpdateScope` and `finOpsTargetVersion` are also exposed as **runtime parameters**, so you can override them for a single manual run.

> Inventory always runs and is read-only; there is no variable for it. Two earlier variable names, `finOpsInventory` and `updateFinOpsVersion`, are retired. If either is still present the script ignores it and logs a one-time warning. See [docs/parameters.md](docs/parameters.md) for details.

Full details and worked examples are in [docs/parameters.md](docs/parameters.md).

## Setup

Full walkthrough is in [docs/setup.md](docs/setup.md). In short:

1. Create the Entra ID app registration and a client secret.
2. Register the service principal as a Power Platform management application, and add it as an application user (System Administrator) in each target environment. See [docs/permissions.md](docs/permissions.md).
3. Create the `D365-TenantAppUpdater` variable group with the three required variables.
4. Add the pipeline from `azure-pipelines.yml` and authorize it to use the variable group.
5. Run with `whatIf` set to `true` first to preview, then run for real.

## Finance and Operations

Two variables govern this phase: `finOpsApplyVersion` (the only on/off switch, default `false`) and `finOpsUpdateScope` (which kind of update is eligible, default `QualityUpdate`).

### Inventory (always on, read-only)

For every detected F&O environment the pipeline reports a single compact line, for example:

```
TPM-DEV04: 10.0.2645.136 (UnifiedDeveloper) - no PQU version available. New version available: 10.0.49.2 [Status: GeneralAvailability]
```

Expand the environment's group to see AOS counts, demo dataset, and the F&O Provisioning App Anchor Solution version (shown for reference only). This runs every time, regardless of `finOpsApplyVersion`.

### Update scope: PQU vs. a new release train

`finOpsversions` returns each available version with Microsoft's own `releaseStage` label - for example `{"version":"10.0.48.7","releaseStage":"QualityUpdate"}` alongside `{"version":"10.0.49.2","releaseStage":"GeneralAvailability"}`. `finOpsUpdateScope` filters against this field directly:

| Value | Displayed as | Selects |
|---|---|---|
| `QualityUpdate` (default) | **PQU** | Only a same-train patch (Microsoft's own "proactive quality update"). |
| `VersionUpdate` | **version update** | Only a move to a new release train. |
| `Any` | - | The numerically highest version, ignoring stage. |

**This does not use the F&O Provisioning App Anchor Solution to classify anything**, and that is a deliberate, hard-won correction. An earlier version did, and it was confirmed live to be unreliable: ten environments sharing the identical live application build reported two different Anchor Solution readings in the same pipeline run. The reason is structural - Microsoft's own automated Unified environment service update rollout does not touch that Dataverse record; only a Dataverse-level solution operation (an environment copy, or an explicit solution import) does. Since the platform already labels each version's `releaseStage` itself, there was never a need for this script to derive that classification from a value that can silently drift from reality.

### Why apply is a single, off-by-default switch

Version apply is implemented and gated behind a live route check, so it begins working automatically when the `finopsversions` route becomes available on your endpoint. That is exactly why it needs to be one explicit, off-by-default variable with nothing else able to enable it: if it were bundled with inventory, or reachable through more than one variable name, the day the route deploys, anyone who had only enabled the phase for the inventory table would silently start applying application versions on their next scheduled run.

### LCS managed environments are never version-updated

`LCSSandbox` and `LCSProduction` environments are **inventoried but deliberately excluded from version apply**, because their application updates are driven through Lifecycle Services rather than the Power Platform API. Controlled by `finOpsDeploymentTypes`, which defaults to the Unified types only.

### A known platform behaviour worth expecting

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real data on another, for the identical environment, token, and api-version, with no configuration change in between. This is reported factually per environment and is **not** counted as a script failure - it reflects the state of the platform at the moment of the call, not a defect in this project. If you see it, simply re-run.

## How to run

- **Manual:** run the pipeline and, if you like, flip the runtime parameters for that run.
- **First run:** set `whatIf` to `true` so it reports without changing anything.
- **Scheduled:** uncomment the `schedules` block in `azure-pipelines.yml`. Decide deliberately whether `finOpsApplyVersion` should be on, and whether `finOpsUpdateScope` should stay at `QualityUpdate` or widen to `VersionUpdate`, for an unattended run.

## Pipelines in this repo

### 1. `azure-pipelines.yml` - the tenant app updater

The main pipeline. Runs `scripts/Update-TenantApps.ps1` to update Dynamics 365 first-party apps across every Dataverse environment, report F&O inventory, and optionally apply F&O versions.

### 2. `sync-from-github.yml` - GitHub to Azure DevOps sync

Optional. Keeps an Azure DevOps mirror of this repository in step with GitHub, so teams that build from Azure DevOps Repos never work from a stale copy.

- Runs on a schedule only. Default cron is weekly, Mondays at 06:00 UTC, with `always: true`.
- Fetches `main` plus tags from the GitHub remote.
- Sync strategy: `reset` (mirror, force-resets the branch) or `ff-only` (safe, fails if histories diverged).
- Pushes using `System.AccessToken`.

One-time Azure DevOps setup, **per project** (repository permissions do not carry across projects):

- **Project Settings > Repositories > (repo) > Security:** grant the build service **Contribute**. For the default `reset` strategy also grant **Force push**.
- If `main` has a branch policy, add the build service as an exception.

## Environment and app scoping

| Control | Type | Effect |
|---|---|---|
| `environmentFilter` | allow-list | Only these environments are processed. Blank means all. |
| `environmentExclude` | deny-list | Always skipped, even if they match the filter. Use it to protect production. |
| `appExclude` | deny-list | Apps always skipped. Matches exact, wildcard, or substring. |
| `finOpsEnvironmentFilter` | allow-list | Extra restriction applied to F&O version apply only, not inventory. |
| `finOpsDeploymentTypes` | allow-list | Deployment types eligible for an F&O version apply. |

> `appExclude` falls back to **substring** matching when the value contains no `*`. A short value like `sales` will match far more than you expect. Prefer the exact unique name, or an explicit wildcard. See [docs/parameters.md](docs/parameters.md).

Worked examples are in [docs/parameters.md](docs/parameters.md).

## Custom Install Experience apps

Some first-party apps use a guided wizard in the Power Platform Admin Center and cannot be installed by the API. The script detects the API's "Custom Install Experience" response and reports those apps as **manual install required** in a summary table rather than failing the run. Add them to `appExclude` if you prefer to silence them entirely. The F&O Provisioning App Anchor Solution is a special case of this and is excluded from Phase 1 entirely, since it is exclusively handled by the Finance and Operations phase.

## Known limitations and roadmap

- Targets Dynamics 365 first-party apps. It does not manage third-party or ISV solutions.
- Available versions depend on what the tenant's release channel exposes.
- The `finopsversions` route has observed intermittent availability. See above.
- LCS managed environments are inventoried only, by design.
- Install operations are triggered but not polled to completion. The run reports the operation id and moves on.
- Roadmap ideas: install completion polling, per-environment approval gates, Teams or email summary notification, parallel installs, and a dry-run report artifact.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

## Author

**Laze Janev** - Dynamics 365 Solution Architect and Microsoft MVP (AI ERP), founder of Commerce Code.

- LinkedIn: [https://www.linkedin.com/in/lazejanev/](https://www.linkedin.com/in/lazejanev/)

If this saved you an afternoon, a star on the repo is appreciated, and I would love to hear how you use it.
