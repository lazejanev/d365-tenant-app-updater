# Parameters and variables

The configuration model is simple: **sign-in details are required, everything else is optional with a built-in default.** To override a default, add a variable with the matching name: on Azure DevOps to the `D365-TenantAppUpdater` variable group, on GitHub as a repository variable (names in [GitHub variable names](#github-variable-names)). If the variable is absent, the default applies. You never edit the YAML to change behavior.

Every setting keeps its v2 name and meaning, so an existing variable group keeps working after the upgrade to v3. New settings in v3 are marked **(v3)**.

## How resolution works

For each optional setting the script resolves the value in this order:

1. An explicit script parameter (used when running the script by hand).
2. A queue-time override (only the settings exposed as [runtime parameters](#runtime-parameters)).
3. The matching environment variable (how the pipeline passes the variable group or repository variables).
4. The built-in default.

An unexpanded Azure DevOps macro (for example `$(bapApiVersion)`, which is what you get when a variable is not defined in the group) is treated as "not set", so the default applies. Placeholder text like `(empty)`, `(none)` or `(all)` is also treated as blank.

Settings that are exposed both as a queue-time runtime parameter and as a library variable resolve as: **runtime override, then library variable, then built-in default.**

## Required variables

| Azure DevOps | GitHub | Secret | Description |
|---|---|---|---|
| `ClientId` | `D365_CLIENT_ID` (variable) | No | Entra ID application (client) id of the service principal. |
| `ClientSecret` | `D365_CLIENT_SECRET` (secret) | **Yes** | Client secret value. Required in `azure-pipelines.yml`. Optional on GitHub, where OpenID Connect is used and the secret is only the backup. Not used by `pipelines/azure-pipelines-federated.yml`. |
| `TenantId` | `D365_TENANT_ID` (variable) | No | Entra ID directory (tenant) id. |

## Sign-in (v3)

| Variable | Default | Description |
|---|---|---|
| `authMode` | `Auto` | `Auto`: OpenID Connect (federated, no secret) when the platform offers it, otherwise the client secret. If the federated sign-in is refused and a secret exists, the run switches to the secret and warns. `Federated`: OIDC only, never the secret. `ClientSecret`: the secret only. |
| `serviceConnectionId` | (blank) | Azure DevOps federated pipeline only: the ID of the workload identity federation service connection, used to request the pipeline's OIDC token. See [setup-azure-devops.md](setup-azure-devops.md#9-federated-sign-in-preview). |

Tokens are cached per API and renewed five minutes before they expire, so long runs keep working.

## Optional variables and their defaults

### Endpoints and API configuration

| Variable | Default | Description |
|---|---|---|
| `authority` | `https://login.microsoftonline.com/<TenantId>/oauth2/v2.0/token` | Token endpoint. Built from `TenantId` when not set. |
| `bapApiRoot` | `https://api.bap.microsoft.com` | BAP admin API base URL. The BAP token scope is derived as `<bapApiRoot>/.default`. |
| `bapApiVersion` | `2026-06-01` | API version for the environments list. |
| `ppApiRoot` | `https://api.powerplatform.com` | Power Platform API base URL, used by App Management and the Finance and Operations routes. |
| `powerPlatformScope` | `https://api.powerplatform.com/.default` | Token scope for the Power Platform API. |
| `appManagementApiVersion` | `2026-05-01-preview` | API version for App Management calls. |
| `finOpsApiVersion` | `2024-10-01` | API version for the Finance and Operations routes. |

### Behavior

| Variable | Default | Description |
|---|---|---|
| `dumpDiagnostics` | `true` | List, per environment, the apps that have no matching managed solution (and so are not evaluated). Everything else (planned actions, holds, the F&O table with live build, train and offered versions) is always in the log and the run summary. |
| `dumpSolutionCatalog` | `false` | Dump every Dataverse managed solution matching a broad generic-app hint list. Separate from `dumpDiagnostics` because on a Sales-heavy environment this alone can run to 150+ lines unrelated to F&O. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install ended in `InstallFailed`. A retry shows as **Retry planned** (Plan) or **Retry started** (Apply), log tag `[RETRY]`, with an empty From. `appExclude` applies to retries too. |
| `whatIf` | `false` | Plan only, wherever it is set (the queue-time **Plan only** dropdown, the variable group, or the GitHub `WHAT_IF` variable). Report what would change without changing anything. In the three-stage pipelines the Plan stage then reports no actions to the Apply stages and logs "whatIf is on: the Apply stages are skipped." Both Apply stages are skipped and no production approval is requested. In the default PlanAndApply mode, `whatIf = true` makes the run a Plan run. |
| `usePacFallback` | `false` | Attempt a PAC CLI install for custom-install apps. Needs the client secret. It is ignored (with a warning) when signing in with OIDC, and the PAC CLI is not installed on GitHub runners. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | (blank) | Deny-list of apps to always skip, matched on unique name, display name, application name or application id. Exact names or `*` wildcards. Partial (substring) matches still work but are deprecated, see [App scoping](#app-scoping-appexclude). |
| `waitForInstallsMinutes` **(v3)** | `0` | `0` (default): trigger the app installs and move on, as in v2. The next run reports the outcome. A number of minutes: wait up to that long for the installs to finish and report each one in the same run (succeeded, failed, still running), with a progress line every minute. F&O version applies run for hours and are always verified by the next run. |
| `failOnIssues` **(v3)** | `false` | When something could not be read or an install failed, the run ends "with issues": orange on Azure DevOps, green with warning annotations on GitHub. Set `true` to fail the run (exit code 1, red) instead, for example to trigger a failure notification. The **Plan** stage is never failed by it, so one unreadable environment does not stop the applies for every other environment: the Apply stages (and PlanAndApply runs) fail instead, and only for problems in their own actions. |

### Production ring (v3)

With the ring on, a production environment only takes a version that a non-production environment in scope **already runs**. Non-production environments update first ("test and break fast"). Production follows on a later run, once the version is proven.

| Variable | Default | Description |
|---|---|---|
| `productionRing` | `true` | `false` restores v2 behaviour: every environment updates as soon as a version is available. |
| `productionEnvironmentTypes` | `Production` | PPAC environment types treated as production. Other types (Sandbox, Developer, Trial, Default) are non-production. An environment whose type is not reported is treated as production (fail safe), and the log warns about it. |
| `productionEnvironments` | (blank) | Extra environment names or ids treated as production, whatever their type (for example a Sandbox used for training). |
| `productionSoakDays` | `0` | Apps only: a non-production environment proves a version only after running it this many days (from the solution's modified date in Dataverse). `0` = proven as soon as it is installed. |

How "proven" is decided:

- **Apps.** At least one non-production environment in scope has the app's managed solution at the target version or newer (and, with `productionSoakDays`, has not changed it for that many days).
- **Finance and Operations.** At least one non-production F&O environment in scope is on a higher release train than the target, or on the same train and the target is no longer in its offered list. Microsoft only offers versions later than the installed one, so a version that is no longer offered is installed (or superseded).
- An F&O environment whose deployment type is `UnifiedProduction` or `LCSProduction` is production, whatever its PPAC type.
- Production actions in a plan were proven when the plan was made. In the three-stage pipelines, production therefore takes what non-production already ran **before** this run: one run behind.

Held items appear under **Held for production** in the run summary, with the reason, so nothing is silently skipped.

### Finance and Operations

The F&O phase has **one on/off switch** (`finOpsApplyVersion`) and **one scope control** (`finOpsUpdateScope`). Inventory always runs and is read-only regardless of either setting.

| Variable | Default | Description |
|---|---|---|
| `finOpsApplyVersion` | `false` | **The only on/off switch.** Set to `true` to apply a new F&O application version on eligible environments. Everything else in this table only refines what/where/which kind an apply targets. None of them enable an apply on their own. |
| `finOpsUpdateScope` | `QualityUpdate` | Restricts **which kind** of available version may be selected. See "How scope is decided" below. Displayed in the log as **PQU** (`QualityUpdate`) or **version update** (`VersionUpdate`). |
| `finOpsTargetVersion` | (blank = highest matching scope) | A specific F&O application version to apply, for example `10.0.49.3`. Blank selects the highest version that matches `finOpsUpdateScope` per environment. A named version is still checked against the scope (unless scope is `Any`) and reported if it doesn't match. |
| `finOpsEnvironmentFilter` | (blank = all detected) | An additional allow-list for the F&O phase (inventory and apply), on top of `environmentFilter` and `environmentExclude`. The apps phase still runs everywhere. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a **version apply**. Inventory is always collected regardless. LCS types are excluded by default. |
| `finOpsScheduleUrl` | Microsoft's PQU schedule (public source of the Learn page) | Where the release map is downloaded from at the start of the F&O phase. `none` disables the download, leaving the built-in map only. You never need to set this. |
| `finOpsBuildTrainMap` | (blank) | **Emergency override only.** Comma-separated `10.0.<build>=<train>` entries (e.g. `10.0.2900=50` or `10.0.2900=10.0.50`), applied on top of everything else. Not needed in normal use. Malformed entries are ignored with a warning. |

#### How scope is decided

Each entry returned by `finopsversions` carries Microsoft's `releaseStage`, for example `{"version":"10.0.49.3","releaseStage":"QualityUpdate"}`. That label describes **the build itself** (10.0.49.3 is a quality update on the 10.0.49 train). It does not say whether the build is on the **environment's** current train. The scope therefore combines `releaseStage` with the **release train** (the 3rd version segment, e.g. `48` in `10.0.48.7`):

| `finOpsUpdateScope` | Selects |
|---|---|
| `QualityUpdate` (default, shown as **PQU**) | `releaseStage` is `QualityUpdate` **and** the version's train equals the environment's current train. Example: an environment on 10.0.48 can get 10.0.48.7, never 10.0.49.3. |
| `VersionUpdate` (shown as **version update**) | The version is on the **next** train (current + 1) **and** is staged `GeneralAvailability` or `QualityUpdate`. Example: an environment on 10.0.48 can get 10.0.49.x, never 10.0.50.x in the same run, and never a build staged anything else (for example a preview). |
| `Any` | Every version returned. The numerically highest is selected. No train or stage restriction. |

**Where the current train comes from.** The environment's **live application build**: `applicationVersion` from `finopsproperties`, fetched fresh on every run (for example `10.0.2645.136`). Every PQU of a release shares one build prefix, published by Microsoft in the "Application Version" column of the [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule). The same page also lists the matching version that `finopsversions` offers, for example:

| PQU train | Application Version (live build) | Provisioning version (offered by `finopsversions`) |
|---|---|---|
| 10.0.47 Release-13 | 10.0.2527.215 | 10.0.47.14 |
| 10.0.48 Release-7 | 10.0.2645.147 | 10.0.48.8 |
| 10.0.49 Release-1 | 10.0.2790.83 | 10.0.49.3 |

**The map is built automatically.** At the start of the F&O phase, every run downloads Microsoft's schedule and reads every row shaped like `10.0.49 PQU-1 ... 10.0.2790.83`, giving build prefix `10.0.2790` = 10.0.49. The log prints the result, e.g. "Release map from Microsoft's PQU schedule (30 PQU rows): ...". When Microsoft publishes a new release, the next run picks it up. Nothing has to be maintained.

Built-in **fallback**, used only when the schedule cannot be downloaded or parsed (the log then shows a warning):

| Build prefix | Release train |
|---|---|
| `10.0.2428` | 10.0.46 |
| `10.0.2527` | 10.0.47 |
| `10.0.2645` | 10.0.48 |
| `10.0.2790` | 10.0.49 |

Order of precedence: built-in fallback, then Microsoft's schedule, then the optional `finOpsBuildTrainMap` override. A build that the schedule lists under two different releases is treated as unknown.

**Fail-safe rule.** If the current train cannot be determined (no `applicationVersion`, a build Microsoft's schedule does not list yet, or an ambiguous build), the apply is **skipped** for that environment, unless the scope is `Any`. The log reads, for example, "current release train unknown (build 10.0.2900.x is not in Microsoft's PQU schedule or the built-in map yet)".

**Lower-train guard (every scope, including `Any`).** A version on a lower train than the live build is never applied, whether picked automatically or set in `finOpsTargetVersion`. Microsoft documents that the PPAC version list for an environment only contains versions later than the one installed (see [Update the Finance and Operations Provisioning app](https://learn.microsoft.com/power-platform/admin/unified-experience/tutorial-update-finance-operations-provisioning-app)). This guard enforces the part the script can verify itself.

**Why not the F&O Provisioning App Anchor Solution.** v2.4.2 read the train from the 3rd segment of the Anchor Solution version in Dataverse. Microsoft has confirmed that this record is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API, which is the path this pipeline uses. After the first apply through this pipeline it is permanently stale: the environments moved to 10.0.49.3 in the v2.4.1 incident still read 10.0.48, so v2.4.2 would have skipped every 10.0.49 PQU for them. v2.4.3 uses the Anchor Solution only to detect that F&O is installed, never its version.

Check the **Train** column of the Finance and Operations table in the run summary when an environment behaves unexpectedly.

> **v2.4.0 and v2.4.1 used `releaseStage` alone.** Because a quality update on a newer train is also staged `QualityUpdate`, `QualityUpdate` scope in those versions could move environments to a new release train. This was confirmed live (10.0.48 environments moved to 10.0.49.3) and fixed in v2.4.2.

> **v2.4.2: train from the Anchor Solution.** It went stale after the first apply through this pipeline, so environments already updated by it were misread. Fixed in v2.4.3 (live build).

> **v2.4.2 and earlier: multi-version lists.** When `finopsversions` returned a bare JSON array with two or more versions, those versions were lost and the environment was reported as "no versions listed". Fixed in v2.4.3.

#### Why apply has exactly one on/off switch

Version apply is implemented against the documented Power Platform API and is gated behind a live route check, so it begins working automatically once the `finopsversions` route is available on your endpoint. That is exactly why it must be a single, explicit, off-by-default variable with nothing else able to enable it: if inventory and apply shared a switch, or if a legacy variable could enable apply as a side effect, then the day the route deploys, anyone who had only enabled the phase for the inventory table would start applying application versions on their next scheduled run without having asked for it.

#### Retired variables

Two earlier names no longer exist: `finOpsInventory` (inventory is unconditional, so a switch for it made no sense) and `updateFinOpsVersion` (an earlier combined switch, superseded by `finOpsApplyVersion`). If either is still present in the variable group, the script ignores it and prints a one-time warning naming exactly which one it found. Remove them. Nothing needs to replace them.

## Run modes (v3)

`scripts/Update-TenantApps.ps1` takes four run parameters. The pipelines set them. You only need them to run by hand.

| Parameter | Values | Effect |
|---|---|---|
| `-Mode` | `PlanAndApply` (default), `Plan`, `Apply` | `Plan` reads the tenant and writes `plan.json`, `summary.md` and `report.json`, changing nothing. `Apply` reads a `plan.json`, re-checks every action against the live tenant and applies it. `PlanAndApply` does both in one run (v2 behaviour). |
| `-Ring` | `All` (default), `NonProduction`, `Production` | Which actions an apply executes. |
| `-PlanFile` | path | The plan to apply. Default: `plan.json` in the output directory. |
| `-OutputDirectory` | path | Where the plan and reports go. Default: the pipeline's artifact staging directory (Azure DevOps), `RUNNER_TEMP` (GitHub), or `./d365-tenant-app-updater-output`. |

Apply never improvises. An action is skipped and reported, and the next plan decides again:

- `[CHANGED]` **Changed since plan**: the app's available version changed since the plan, an F&O version is no longer offered, or the app's installed version can no longer be read. Apply never installs over an app whose installed version is unknown.
- `[CURRENT]` **Already current**: the environment already has the version.
- `[STOPPED]` **Stopped by settings**: the current settings no longer allow the action. Apply checks `environmentExclude`, `environmentFilter`, `appExclude` (also by application id and application name), `retryFailedInstalls`, `finOpsApplyVersion`, `finOpsEnvironmentFilter`, `finOpsUpdateScope`, `finOpsTargetVersion` and `finOpsDeploymentTypes`. It also stops a non-production action when the environment is now production (through `productionEnvironments` or `productionEnvironmentTypes`), and a production action when `productionRing` was turned on after a plan made without it.

`plan.json` stores a `settings` snapshot of the values the plan was made with, so Apply can compare them.

Every run writes **summary.md** (shown on the run page: the Extensions tab on Azure DevOps, the job summary on GitHub) and **report.json**. Environments and apps are processed and listed A to Z: case-insensitive, numbers in numeric order (Dev2 before Dev10), and the same order on every agent and locale. Within an apply, non-production goes before production.

## Runtime parameters

Some settings are also exposed as queue-time inputs, so you can override them for a single manual run without editing the variable group. `azure-pipelines.yml` has all six below. `pipelines/azure-pipelines-federated.yml` has five (no `usePacFallback`). The GitHub workflow has four (no `usePacFallback` and no `productionApprovalEnvironment`).

| Parameter | Values | Effect |
|---|---|---|
| Plan only (`whatIf`) | `useLibraryOrDefault`, `true`, `false` | Overrides the library/default for this run. `true` means Plan only: both Apply stages are skipped. |
| Try PAC CLI fallback (`usePacFallback`) | `useLibraryOrDefault`, `true`, `false` | Same override behavior. When effectively true, the pipeline installs the PAC CLI on the agent. Azure DevOps client-secret pipeline only. |
| Apply F&O version (`finOpsApplyVersion`) | `useLibraryOrDefault`, `true`, `false` | **Changes environments.** Enables version apply for this run only. |
| F&O update scope (`finOpsUpdateScope`) | `useLibraryOrDefault`, `QualityUpdate`, `VersionUpdate`, `Any` | Overrides which kind of version is selected, for this run only. |
| F&O target version (`finOpsTargetVersion`) | free text | A specific version for this run. Blank defers to the library value or highest matching scope. |
| Production approval environment (`productionApprovalEnvironment`) | `none` (default), or the name of an environment | Azure DevOps only. Not a setting of the script, so it has no variable. Names an existing Azure DevOps environment with an Approvals check. **Apply: production** then deploys to it and waits for approval. See [setup-azure-devops.md](setup-azure-devops.md#optional-a-person-approves-production). |

On GitHub the choice that defers to the repository variable or default is `useVariableOrDefault`.

## Environment scoping: how filter and exclude work

Two independent controls decide which environments run.

### `environmentFilter` - the allow-list

Comma-separated environment **names or ids**. If set, only those environments are processed. Blank means all. Matching is case-insensitive on either the display name or the id.

### `environmentExclude` - the deny-list

Comma-separated environment **names or ids** that are always skipped, even if they match the filter. Use it to protect production.

### The combined rule

```
(environmentFilter is blank OR the environment matches environmentFilter)
AND
the environment does NOT match environmentExclude
```

The exclude list always wins.

### Worked examples

| Goal | `environmentFilter` | `environmentExclude` | Result |
|---|---|---|---|
| Update everything | (blank) | (blank) | Every Dataverse environment. |
| Update everything except production | (blank) | `Production` | All, but Production is skipped. |
| Update only Dev and Test | `Dev, Test` | (blank) | Only Dev and Test. |
| Update all but never touch UAT | (blank) | `UAT` | All except UAT. |
| Target a list, still protect one | `Dev, Test, UAT` | `UAT` | Dev and Test only. |
| Target one environment by id | `2f3b...id...` | (blank) | Only that environment. |

## App scoping: `appExclude`

Comma-separated application **names, uniqueNames, or ids** that are always skipped on every environment.

Matching is tried in this order:

1. **Exact** - `msdyn_AppProfileManagerAnchor` matches only that app.
2. **Wildcard** - `msdyn_*Anchor` matches anything fitting the pattern. Use this when you want control.
3. **Substring (deprecated)** - any app whose name *contains* the value is matched.

> **Substring matching is deprecated in v3.** It still works, so nothing changes for existing variable groups, but each value that only matches as part of a name is reported once per run as a warning, naming the app it matched and the wildcard to use instead. It will be removed in a future major version.
> A short generic value is risky: `sales` would exclude every app with "sales" anywhere in its unique name, localized name, application name or id. Use the exact unique name, or an explicit wildcard such as `*sales*` so the intent is visible.

The default is blank. Apps that require the Power Platform Admin Center install wizard are reported as **Install in admin center** (`[MANUAL]`) rather than hidden, so you can see what still needs a human. Add them to `appExclude` if you would rather silence them.

The F&O Provisioning App never needs to be added here. Only the real provisioning app (matched by its unique name) is left out of the generic install loop, because it is updated only through the dedicated Finance and Operations route. Other apps with "finance and operations" in their name, such as Copilot for finance and operations apps, are updated like any other app. Add them to `appExclude` if you want to skip them.

## Finance and Operations scoping

Two additional controls apply only to the Finance and Operations phase.

### `finOpsEnvironmentFilter`

An extra allow-list layered on top of the normal environment scoping. Environments outside it are left out of the F&O phase entirely (no inventory row, no apply). The apps phase still runs for them. Useful when you want app updates everywhere but F&O handled for a subset.

### Production ring and F&O

A non-production F&O environment proves a version for production only when this tool can update it (its deployment type is in `finOpsDeploymentTypes`) and its offered list was read successfully, and either it is on a higher release train than the version, or it is on the same train, its live build is higher than production's, and the version is no longer offered to it. An empty or failed version list on its own never counts as proof.

### `finOpsDeploymentTypes`

Controls which deployment types are eligible for a **version apply**. Inventory is collected for every F&O environment regardless of this setting.

| Deployment type | In default list | Behavior |
|---|---|---|
| `UnifiedDeveloper` | Yes | Eligible for version apply. |
| `UnifiedSandbox` | Yes | Eligible for version apply. |
| `UnifiedProduction` | Yes | Eligible for version apply. |
| `LCSSandbox` | No | Inventory only. Updated through Lifecycle Services. |
| `LCSProduction` | No | Inventory only. Updated through Lifecycle Services. |

LCS managed environments are excluded deliberately. Their application updates are driven through Lifecycle Services, not the Power Platform API, so attempting an apply would be incorrect.

## Example: safe production-protected preview

Variable group:

- `whatIf = true`
- `environmentExclude = Production`

This reports what would change across every environment except Production, without changing anything. (Since v3 the production ring already holds production back until non-production runs a version. Excluding production is only needed if you never want the pipeline to touch it.) F&O inventory is included, because it always runs and is read-only.

## Example: inventory everywhere, no version changes

Nothing to configure. This is the default. `finOpsApplyVersion` is `false`, so you get the inventory table and no environment is modified.

## Example: apply only proactive quality updates (PQU) on the dev estate

- `finOpsApplyVersion = true`
- `finOpsUpdateScope = QualityUpdate` (the default, can be omitted)
- `finOpsEnvironmentFilter = Dev01, Dev02, Dev03`

> Environment names above are illustrative placeholders. Substitute your own environment display names or ids.

Phase 1 still runs against every environment. Inventory is reported for every F&O environment. Version apply is attempted only on the three listed, and only when a version staged `QualityUpdate` exists **on that environment's current release train**. If the only offer is on a newer train, the log reports "no PQU version available for 10.0.48" and nothing is applied.

## Example: move onto the next release train deliberately

- `finOpsApplyVersion = true`
- `finOpsUpdateScope = VersionUpdate`

Use this once you have decided you want to move an environment onto a new release wave (for example 10.0.48 to 10.0.49). It moves **one** train per run and only to builds staged `GeneralAvailability` or `QualityUpdate`. If only a later train is offered (for example 10.0.50 for an environment on 10.0.48), the log reports "no version update (next train) available" and nothing is applied.

## Example: jump more than one release train deliberately

- `finOpsApplyVersion = true`
- `finOpsUpdateScope = Any`
- `finOpsTargetVersion = 10.0.50.1` (the exact version you want)
- `finOpsEnvironmentFilter = Dev01`

`Any` lifts the train and stage restrictions, and the explicit target makes the jump a deliberate choice for the named environment. The lower-train guard still applies.

Run any apply configuration with `whatIf = true` first.

## GitHub variable names

On GitHub, settings are repository variables (**Settings > Secrets and variables > Actions > Variables**). The workflow maps them to the setting names:

| Setting | GitHub repository variable |
|---|---|
| ClientId / TenantId | `D365_CLIENT_ID`, `D365_TENANT_ID` |
| ClientSecret (optional backup) | secret `D365_CLIENT_SECRET` |
| authMode | `AUTH_MODE` |
| whatIf | `WHAT_IF` |
| environmentFilter / environmentExclude | `ENVIRONMENT_FILTER`, `ENVIRONMENT_EXCLUDE` |
| appExclude | `APP_EXCLUDE` |
| retryFailedInstalls | `RETRY_FAILED_INSTALLS` |
| dumpDiagnostics / dumpSolutionCatalog | `DUMP_DIAGNOSTICS`, `DUMP_SOLUTION_CATALOG` |
| usePacFallback | `USE_PAC_FALLBACK` (the PAC CLI is not installed on GitHub runners, see [setup-github.md](setup-github.md#8-what-differs-from-azure-devops)) |
| finOpsApplyVersion | `FINOPS_APPLY_VERSION` |
| finOpsUpdateScope | `FINOPS_UPDATE_SCOPE` |
| finOpsTargetVersion | `FINOPS_TARGET_VERSION` |
| finOpsEnvironmentFilter | `FINOPS_ENVIRONMENT_FILTER` |
| finOpsDeploymentTypes | `FINOPS_DEPLOYMENT_TYPES` |
| finOpsScheduleUrl / finOpsBuildTrainMap | `FINOPS_SCHEDULE_URL`, `FINOPS_BUILD_TRAIN_MAP` |
| productionRing | `PRODUCTION_RING` |
| productionEnvironmentTypes / productionEnvironments | `PRODUCTION_ENVIRONMENT_TYPES`, `PRODUCTION_ENVIRONMENTS` |
| productionSoakDays | `PRODUCTION_SOAK_DAYS` |
| waitForInstallsMinutes | `WAIT_FOR_INSTALLS_MINUTES` |
| failOnIssues | `FAIL_ON_ISSUES` |

The endpoint and API-version settings are not mapped in the workflow. Their defaults are correct. Add a line under `env:` in `.github/workflows/tenant-app-updater.yml` if you ever need one.
