# d365-tenant-app-updater

**Automatically update all Dynamics 365 first-party (Dataverse) apps across an entire tenant, and report Finance and Operations environment inventory, from a single Azure DevOps pipeline.**

![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)
![Version 2.4.3](https://img.shields.io/badge/version-2.4.3-1e90ff)
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

> **Important: upgrade from v2.4.0, v2.4.1 or v2.4.2**
> With `finOpsApplyVersion = true` and `finOpsUpdateScope = QualityUpdate`, v2.4.0 and v2.4.1 could move an environment to a **new release train** (for example 10.0.48 to 10.0.49), because they only checked Microsoft's `releaseStage` label. v2.4.2 added the release-train check. v2.4.3 adds a never-older guard, limits `VersionUpdate` to the next train and released builds, and fixes a parsing bug that reported multi-version lists as "no versions listed". Upgrade before running with `finOpsApplyVersion = true`.

## The goal

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Open the Power Platform Admin Center, pick an environment, open its Dynamics 365 apps, check each one for an update, install, wait, and then repeat for the next environment, and the next. Multiply that by every environment on the tenant and every first-party app, and app maintenance quietly eats hours you never get back.

This project turns that manual chore into a hands-off, repeatable, tenant-wide operation. A service principal authenticates non-interactively, the pipeline discovers every Dataverse environment on the tenant, compares the installed version of each app against the latest available version, and installs the updates that are genuinely newer. It can retry previously failed installs, protect specific environments, skip specific apps, and preview everything without changing a thing.

It also reports a **Finance and Operations inventory** across the tenant, and can optionally apply F&O application version updates, distinguishing between a quality update on the current release train and a move to a new release train.

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
        |     using Microsoft's releaseStage AND the environment's current
        |     release train, and never a version at or below the
        |     environment's Anchor Solution version. LCS managed
        |     environments are inventoried but never version-updated.
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
| `finOpsUpdateScope` | `QualityUpdate` | Which kind of version apply may select: `QualityUpdate` (PQU on the current release train), `VersionUpdate` (the next release train, released builds only), or `Any`. |
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
Dev04: 10.0.2645.136 (UnifiedDeveloper) - no PQU version available for 10.0.48. New version available: 10.0.49.3 [Status: QualityUpdate]
```

> Environment names above (`Dev01`, `Dev02`, ...) are illustrative placeholders. Your own log will show your actual environment display names.

Expand the environment's group to see AOS counts, demo dataset, the F&O Provisioning App Anchor Solution version and the current release train it implies. This runs every time, regardless of `finOpsApplyVersion`.

### Update scope: PQU vs. a new release train

`finopsversions` returns each available version with Microsoft's `releaseStage` label, for example `{"version":"10.0.49.3","releaseStage":"QualityUpdate"}`. That label describes **the build itself**: 10.0.49.3 is a quality update on the 10.0.49 train. It does **not** say whether that build is on **your environment's** train. So the scope uses two checks:

| Value | Displayed as | Selects |
|---|---|---|
| `QualityUpdate` (default) | **PQU** | `releaseStage` is `QualityUpdate` **and** the version is on the environment's current release train (10.0.48.x stays on 10.0.48). |
| `VersionUpdate` | **version update** | The version is on the **next** release train (current + 1, e.g. 10.0.48 to 10.0.49) and is staged `GeneralAvailability` or `QualityUpdate`. It never jumps several trains at once and never picks a preview or unknown stage. |
| `Any` | - | The numerically highest version, no train or stage restriction. |

The environment's current release train is the 3rd segment of the F&O Provisioning App Anchor Solution version (the `48` in `10.0.48.6`). That solution's version lags behind the live environment, but it never runs ahead of it.

**If the current train cannot be determined, the apply is skipped** (unless the scope is `Any`). The design is fail-safe: it can miss a patch, but `QualityUpdate` can never move an environment to a new release train.

**Never older than the Anchor Solution (every scope).** Because the Anchor Solution lags but never leads, its full version is a lower bound on what the environment is running. A version at or below it is never applied, even with `Any` or an explicit `finOpsTargetVersion`. The log reads "no eligible version newer than the Anchor Solution". The script does not rely on the apply endpoint to refuse a downgrade.

**Known limitation.** The Anchor Solution is not updated by every update path. If an environment has moved to a new train but its Anchor Solution still shows the old one, `QualityUpdate` skips it, and `VersionUpdate` may treat a patch on the real train as the "next train". Neither can apply anything at or below the Anchor, or more than one train past it. See [docs/parameters.md](docs/parameters.md) for the one residual case, which observed platform behaviour suggests does not occur. Check the "Current train" line in the environment's diagnostic detail if an environment is unexpectedly skipped.

To move more than one release train in a single run, set `finOpsUpdateScope = Any` **and** an explicit `finOpsTargetVersion`, so the jump is a deliberate choice.

### Why apply is a single, off-by-default switch

Version apply is implemented and gated behind a live route check, so it begins working automatically when the `finopsversions` route becomes available on your endpoint. That is exactly why it needs to be one explicit, off-by-default variable with nothing else able to enable it: if it were bundled with inventory, or reachable through more than one variable name, the day the route deploys, anyone who had only enabled the phase for the inventory table would silently start applying application versions on their next scheduled run.

### LCS managed environments are never version-updated

`LCSSandbox` and `LCSProduction` environments are **inventoried but deliberately excluded from version apply**, because their application updates are driven through Lifecycle Services rather than the Power Platform API. Controlled by `finOpsDeploymentTypes`, which defaults to the Unified types only.

### A known platform behaviour worth expecting

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real data on another, for the identical environment, token, and api-version, with no configuration change in between. This is reported factually per environment and is **not** counted as a script failure. If you see it, simply re-run.

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
- The current F&O release train is read from the Anchor Solution, which does not update on every path. `QualityUpdate` skips an environment rather than guess when this is unclear.
- Tokens are refreshed after 45 minutes, so long runs across many environments keep working within the 180-minute job timeout.
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
