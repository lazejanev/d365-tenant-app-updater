# d365-tenant-app-updater

**Keep every Dynamics 365 first-party app, and Finance and Operations, up to date across an entire tenant, from Azure DevOps or GitHub Actions. Non-production first, production once it is proven.**

![License: MIT](https://img.shields.io/badge/license-MIT-2ea44f)
![Version 3.0.0](https://img.shields.io/badge/version-3.0.0-1e90ff)
[![CI](https://github.com/lazejanev/d365-tenant-app-updater/actions/workflows/ci.yml/badge.svg)](https://github.com/lazejanev/d365-tenant-app-updater/actions/workflows/ci.yml)
![PRs welcome](https://img.shields.io/badge/PRs-welcome-0b3d91)
![Community project](https://img.shields.io/badge/status-community%20project-111827)

![D365 F&O](https://img.shields.io/badge/Dynamics%20365%20F%26O-002050?logo=microsoftdynamics365&logoColor=white)
![Power Platform](https://img.shields.io/badge/Power%20Platform-742774?logo=microsoftpowerplatform&logoColor=white)
![Dataverse](https://img.shields.io/badge/Dataverse-0067B8?logo=microsoft&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D7?logo=azuredevops&logoColor=white)
![GitHub Actions](https://img.shields.io/badge/GitHub%20Actions-2088FF?logo=githubactions&logoColor=white)
![PowerShell 7](https://img.shields.io/badge/PowerShell%207-5391FE?logo=powershell&logoColor=white)

**Contents:** [Goal](#the-goal) | [What's new in v3](#whats-new-in-v3) | [How it works](#how-it-works) | [Production ring](#production-ring) | [Requirements](#requirements) | [Setup](#setup) | [Configuration](#configuration) | [Finance and Operations](#finance-and-operations) | [Pipelines](#pipelines-and-workflows-in-this-repo) | [Parameters](docs/parameters.md)

> **Note**
> Community project. This is not an official Microsoft tool. Test it in a non-production tenant or environment before you point it at anything that matters.

> **Upgrading from v2?** Your variable group keeps working. Production is now held back until non-production runs a version, PowerShell 7.2 is required, and the pipeline has three stages. Read [docs/upgrading-to-v3.md](docs/upgrading-to-v3.md).

## The goal

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Open the Power Platform Admin Center, pick an environment, open its Dynamics 365 apps, check each one for an update, install, wait, and then repeat for the next environment, and the next. Multiply that by every environment on the tenant and every first-party app, and app maintenance quietly eats hours you never get back.

This project turns that chore into a hands-off, repeatable, tenant-wide operation. A service principal signs in non-interactively, the run discovers every Dataverse environment on the tenant, compares the installed version of each app with the latest available version, and installs the updates that are genuinely newer. Only apps already installed in an environment are touched; nothing new is ever installed.

It also reports a **Finance and Operations inventory** across the tenant, and can apply F&O quality updates (PQUs) or move to the next release, with guards that make it impossible to jump further than you asked.

Non-production environments update as soon as something is available, so you test and break fast. Production follows once a non-production environment has run the version.

## What's new in v3

- **Production ring, on by default.** Production only takes what non-production already runs. Everything held back is listed with the reason.
- **Plan, then apply.** Three stages: Plan (changes nothing), Apply non-production, Apply production. Optional approval on production.
- **GitHub Actions**, alongside Azure DevOps. Same module, same rules.
- **No client secret needed.** OpenID Connect on GitHub, workload identity federation on Azure DevOps (preview). The secret still works, and is the backup.
- **You see the outcome.** App installs are followed and reported; every run publishes a summary on the run page.
- **A to Z.** Environments and apps are processed and reported alphabetically.
- **Tested.** 113 automated tests on every change, no tenant required.

Full list: [CHANGELOG.md](CHANGELOG.md).

## How it works

```
Azure DevOps (azure-pipelines.yml)  or  GitHub Actions (.github/workflows/tenant-app-updater.yml)
        |
        v
  scripts/Update-TenantApps.ps1  ->  D365TenantAppUpdater module (src/)
        |
   ===== PLAN (changes nothing) =====
        |  Sign in (client secret, or federated: GitHub OIDC / Azure DevOps WIF)
        |  1. List every environment (BAP admin API), keep Dataverse-linked ones,
        |     apply environmentFilter / environmentExclude, sort A to Z,
        |     tag each Production or NonProduction.
        |  2. Per environment, collect:
        |       AVAILABLE apps <- /appmanagement/environments/{id}/applicationPackages
        |       INSTALLED      <- {instanceUrl}/api/data/v9.2/solutions (managed)
        |       F&O (if installed): live build (finopsproperties), offered
        |       versions (finopsversions), maintenance window
        |  3. Decide, per app (A to Z):
        |       update only when available is strictly newer than installed;
        |       production only when a non-production environment runs it.
        |     Per F&O environment: target per finOpsUpdateScope, never a lower
        |     train, production only when proven.
        |  -> plan.json, summary.md, report.json
        |
   ===== APPLY non-production, then APPLY production =====
        |  4. Re-check each action against the live tenant, then install
        |     (POST .../install) or apply (POST .../finopsversions/{v}/apply).
        |  5. Wait for app installs (waitForInstallsMinutes) and report each one.
        v
   Updated tenant + summary on the run page
```

**Why installed versions come from Dataverse.** The App Management API tells you which apps exist and the latest **available** version, but it is not a reliable source for what is **installed**. The trustworthy source is the app's managed solution version inside each environment's Dataverse. That is why the service principal needs an application-user role in every environment.

**Why it never downgrades.** An app can legitimately be installed at a version newer than the catalog's advertised version. The run only acts when available is **strictly greater** than installed.

## Production ring

| | Non-production | Production |
|---|---|---|
| Which environments | Everything else: Sandbox, Developer, Trial, ... | PPAC type Production, anything in `productionEnvironments`, F&O `UnifiedProduction` / `LCSProduction` |
| Apps | Updated as soon as a newer version is available | Updated when at least one non-production environment already has that version or newer (optionally for `productionSoakDays`) |
| Finance and Operations | Per `finOpsUpdateScope` | Same, once a non-production F&O environment runs the version |
| Approval | No | Optional (environment `d365-production`) |

On a nightly schedule this means: non-production updates every night; production updates the night after non-production has run the version. Set `productionRing = false` to update everything at once, as in v2. Details: [docs/parameters.md](docs/parameters.md#production-ring-v3).

## Requirements

- **Azure DevOps** (project, variable group) **or GitHub** (repository with Actions). Microsoft-hosted agents / GitHub-hosted runners are fine.
- **PowerShell 7.2 or later** (preinstalled on both).
- **Entra ID app registration** (service principal) with a **client secret or a federated credential**.
- **Power Platform Administrator** rights, used once to register the service principal as a management application (`New-PowerAppManagementApp`).
- **Application user with a security role** (for example System Administrator) for the service principal in **each target environment's Dataverse**.
- Outbound HTTPS to `raw.githubusercontent.com` for Microsoft's PQU schedule (hosted agents have it).

Full permission setup is in [docs/permissions.md](docs/permissions.md). It is the most common reason a fresh tenant fails, so read it before the first run.

## Setup

| Platform | Guide | Sign-in |
|---|---|---|
| Azure DevOps | [docs/setup-azure-devops.md](docs/setup-azure-devops.md) | Client secret (`azure-pipelines.yml`), or workload identity federation (`azure-pipelines-federated.yml`, preview) |
| GitHub Actions | [docs/setup-github.md](docs/setup-github.md) | OpenID Connect, client secret as backup |

In short:

1. Create the Entra ID app registration.
2. Register it as a Power Platform management application, and add it as an application user in each environment ([permissions](docs/permissions.md)).
3. Azure DevOps: create the `D365-TenantAppUpdater` variable group (`ClientId`, `ClientSecret`, `TenantId`) and add `azure-pipelines.yml`. GitHub: add the federated credentials and the `D365_CLIENT_ID` / `D365_TENANT_ID` variables.
4. Run with **Plan only** = `true` and read the summary on the run page.
5. Run for real. Optionally schedule it.

## Configuration

- **Only sign-in details are required.** Everything else has a built-in default.
- To change a default, add a variable with the matching name (Azure DevOps variable group) or its UPPER_SNAKE name (GitHub repository variable). No YAML editing.

The most used settings:

| Variable | Default | What it does |
|---|---|---|
| `whatIf` | `false` | Plan only. Report what would change, change nothing. |
| `productionRing` | `true` | Production only takes versions non-production already runs. |
| `productionEnvironments` | (blank) | Extra environments to treat as production (names or ids). |
| `productionSoakDays` | `0` | Apps: how long non-production must run a version before production gets it. |
| `environmentFilter` / `environmentExclude` | (all) / (none) | Which environments are in scope. |
| `appExclude` | (blank) | Apps to always skip (exact names or `*` wildcards). |
| `waitForInstallsMinutes` | `30` | How long to follow app installs. `0` = do not wait. |
| `finOpsApplyVersion` | `false` | **The only F&O on/off switch.** Changes environments when true. |
| `finOpsUpdateScope` | `QualityUpdate` | `QualityUpdate` (PQU on the current release), `VersionUpdate` (next release only), `Any`. |
| `authMode` | `Auto` | `Auto` (federated when available, secret as backup), `Federated`, `ClientSecret`. |
| `failOnIssues` | `false` | Fail the Apply stages (not Plan) when something could not be read or an install failed. |

Every setting, the run modes and the GitHub names: [docs/parameters.md](docs/parameters.md).

## Finance and Operations

Two variables govern this phase: `finOpsApplyVersion` (the only on/off switch, default `false`) and `finOpsUpdateScope` (which kind of update is eligible, default `QualityUpdate`).

### Inventory (always on, read-only)

For every detected F&O environment the run summary has one row: live application build and its release train (for example `10.0.2645.136` = `10.0.48`), platform, deployment type, maintenance window, and the versions Microsoft offers. The log has one line per environment, for example:

```
Dev04 [NonProduction]: 10.0.2645.136 [10.0.48] - no PQU version available for 10.0.48. Offered: 10.0.49.3 [QualityUpdate]
```

> Environment names above (`Dev01`, `Dev02`, ...) are illustrative placeholders.

This runs every time, regardless of `finOpsApplyVersion`.

### Update scope: PQU vs. a new release train

`finopsversions` returns each available version with Microsoft's `releaseStage` label, for example `{"version":"10.0.49.3","releaseStage":"QualityUpdate"}`. That label describes **the build itself**: 10.0.49.3 is a quality update on the 10.0.49 train. It does **not** say whether that build is on **your environment's** train. So the scope uses two checks:

| Value | Displayed as | Selects |
|---|---|---|
| `QualityUpdate` (default) | **PQU** | `releaseStage` is `QualityUpdate` **and** the version is on the environment's current release train (10.0.48.x stays on 10.0.48). |
| `VersionUpdate` | **version update** | The version is on the **next** release train (current + 1, e.g. 10.0.48 to 10.0.49) and is staged `GeneralAvailability` or `QualityUpdate`. It never jumps several trains at once and never picks a preview or unknown stage. |
| `Any` | - | The numerically highest version, no train or stage restriction. |

### Where the current release train comes from

From the environment's **live application build**, the `applicationVersion` that `finopsproperties` returns on every run (for example `10.0.2645.136`). Every PQU of a release shares one build prefix, which Microsoft publishes in the [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule):

| Build prefix | Release train |
|---|---|
| `10.0.2428` | 10.0.46 |
| `10.0.2527` | 10.0.47 |
| `10.0.2645` | 10.0.48 |
| `10.0.2790` | 10.0.49 |

**Nothing to maintain.** At the start of the Finance and Operations phase, every run downloads Microsoft's schedule (from the public source of that page) and builds this map from it. When Microsoft publishes a new release, the next run picks it up. The table above is only the built-in fallback, used if the download fails, and the log says when that happens.

**If the build is still unknown, the apply is skipped** (unless the scope is `Any`). That happens only for a release Microsoft has not yet added to its schedule, or when the schedule cannot be downloaded and the release is newer than 10.0.49. The design is fail-safe: it can miss a patch, but `QualityUpdate` can never move an environment to a new release train.

**Never a lower train (every scope).** A version on a lower train than the live build is never applied, even with `Any` or an explicit `finOpsTargetVersion`. Microsoft also documents that the version list only offers versions later than the installed one.

**Why not the F&O Provisioning App Anchor Solution.** Microsoft has confirmed that the Anchor Solution's version in Dataverse is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API that this pipeline uses. After the first apply it is permanently stale. It is used only to detect that F&O is installed, never its version.

**Production F&O environments follow the production ring**: a sandbox has to run a version (be on a later train, or no longer be offered it) before production gets it.

To move more than one release train in a single run, set `finOpsUpdateScope = Any` **and** an explicit `finOpsTargetVersion`, so the jump is a deliberate choice.

### LCS managed environments are never version-updated

`LCSSandbox` and `LCSProduction` environments are **inventoried but deliberately excluded from version apply**, because their application updates are driven through Lifecycle Services rather than the Power Platform API. Controlled by `finOpsDeploymentTypes`, which defaults to the Unified types only.

### A known platform behaviour worth expecting

The `finopsversions` route has been observed to intermittently return HTTP 404 `RouteNotFound` on one run and a genuine HTTP 200 with real data on another, for the identical environment, token, and api-version, with no configuration change in between. This is reported per environment and is **not** counted as a failure. If you see it, simply re-run.

## Pipelines and workflows in this repo

| File | Platform | What it does |
|---|---|---|
| `azure-pipelines.yml` | Azure DevOps | The updater, client-secret sign-in. Plan, Apply non-production, Apply production. |
| `azure-pipelines-federated.yml` | Azure DevOps | The same, with workload identity federation (preview). |
| `pipelines/templates/*.yml` | Azure DevOps | Stages and steps shared by both. |
| `sync-from-github.yml` | Azure DevOps | Optional. Keeps an Azure DevOps copy in step with the **latest GitHub release** (or `main`). Weekly, Mondays 06:00 UTC. Needs Contribute (and Force push for `reset`) for the build service on the repository, per project. |
| `.github/workflows/tenant-app-updater.yml` | GitHub | The updater: plan, apply-nonproduction, apply-production. |
| `.github/workflows/ci.yml` | GitHub | Tests, PSScriptAnalyzer and YAML checks on every pull request. |
| `.github/workflows/release.yml` | GitHub | Publishes a GitHub release when a version tag is pushed. |

### What each run produces

- **summary.md**, shown on the run page (Azure DevOps Extensions tab, GitHub job summary): planned actions or results, **Held for production**, **Needs attention**, all environments A to Z, and the F&O table.
- **plan.json** and **report.json**, published as run artifacts.
- The log, with one section per environment in the same order.

A run where something could not be read or an install failed ends **with issues** (orange on Azure DevOps, warning annotations on GitHub), so a missing application user in one environment never hides behind a green tick. Sign-in or discovery failures fail the run.

## Environment and app scoping

| Control | Type | Effect |
|---|---|---|
| `environmentFilter` | allow-list | Only these environments are processed. Blank means all. |
| `environmentExclude` | deny-list | Always skipped, even if they match the filter. |
| `appExclude` | deny-list | Apps always skipped. Exact name or `*` wildcard. Partial matches still work but are deprecated. |
| `finOpsEnvironmentFilter` | allow-list | Extra restriction for the F&O phase (inventory and apply). |
| `finOpsDeploymentTypes` | allow-list | Deployment types eligible for an F&O version apply. |

Worked examples are in [docs/parameters.md](docs/parameters.md).

## Custom Install Experience apps

Some first-party apps use a guided wizard in the Power Platform Admin Center and cannot be installed by the API. The run detects the API's "Custom Install Experience" response and reports those apps as **needs the admin center install wizard** rather than failing. Add them to `appExclude` to silence them. The F&O Provisioning App is never sent to the apps phase; it is handled by the Finance and Operations phase.

## Known limitations

- Targets Dynamics 365 first-party apps. It does not manage third-party or ISV solutions, and never installs an app that is not already installed.
- Available versions depend on what the tenant's release channel exposes.
- F&O version applies run for hours; the run triggers them and the next run verifies them.
- `finopsversions` has shown intermittent `RouteNotFound` responses. See above.
- LCS managed environments are inventoried only, by design.
- `azure-pipelines-federated.yml` is preview until confirmed in more organizations.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md): the module layout, how to run the tests, and the invariants that keep this safe.

## License

MIT. See [LICENSE](LICENSE).

## Author

**Laze Janev** - Dynamics 365 Solution Architect and Microsoft MVP (AI ERP), founder of Commerce Code.

- LinkedIn: [https://www.linkedin.com/in/lazejanev/](https://www.linkedin.com/in/lazejanev/)

If this saved you an afternoon, a star on the repo is appreciated, and I would love to hear how you use it.
