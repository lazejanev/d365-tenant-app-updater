# Parameters and variables

The configuration model is simple: **three variables are required, everything else is optional with a built-in default.** To override a default, add a variable with the matching name to the `D365-TenantAppUpdater` variable group. If the variable is absent, the script uses its default. You never edit the YAML to change behavior.

## How resolution works

For each optional setting the script resolves the value in this order:

1. An explicit script parameter (used when running the script by hand).
2. The matching environment variable (how the pipeline passes overrides from the variable group).
3. The built-in default.

An unexpanded Azure DevOps macro (for example `$(bapApiVersion)`, which is what you get when a variable is not defined in the group) is treated as "not set", so the default applies. Placeholder text like `(empty)`, `(none)` or `(all)` is also treated as blank.

Settings that are exposed both as a queue-time runtime parameter and as a library variable resolve as: **runtime override, then library variable, then built-in default.**

## Required variables

| Variable | Secret | Description |
|---|---|---|
| `ClientId` | No | Entra ID application (client) id of the service principal. |
| `ClientSecret` | **Yes** | Client secret value. Always mark as secret. |
| `TenantId` | No | Entra ID directory (tenant) id. |

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
| `dumpDiagnostics` | `true` | Print per-environment diagnostic detail (installed-vs-available diffs, F&O AOS/demo detail, current release train and the build prefix it came from). |
| `dumpSolutionCatalog` | `false` | Dump every Dataverse managed solution matching a broad generic-app hint list. Separate from `dumpDiagnostics` because on a Sales-heavy environment this alone can run to 150+ lines unrelated to F&O. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install ended in `InstallFailed`. |
| `whatIf` | `false` | Plan only. Report what would change without changing anything. |
| `usePacFallback` | `false` | Attempt a PAC CLI install for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | (blank) | Deny-list of app names/ids to always skip. |

### Finance and Operations

The F&O phase has **one on/off switch** (`finOpsApplyVersion`) and **one scope control** (`finOpsUpdateScope`). Inventory always runs and is read-only regardless of either setting.

| Variable | Default | Description |
|---|---|---|
| `finOpsApplyVersion` | `false` | **The only on/off switch.** Set to `true` to apply a new F&O application version on eligible environments. Everything else in this table only refines what/where/which kind an apply targets; none of them enable an apply on their own. |
| `finOpsUpdateScope` | `QualityUpdate` | Restricts **which kind** of available version may be selected. See "How scope is decided" below. Displayed in the log as **PQU** (`QualityUpdate`) or **version update** (`VersionUpdate`). |
| `finOpsTargetVersion` | (blank = highest matching scope) | A specific F&O application version to apply, for example `10.0.49.3`. Blank selects the highest version that matches `finOpsUpdateScope` per environment. A named version is still checked against the scope (unless scope is `Any`) and reported if it doesn't match. |
| `finOpsEnvironmentFilter` | (blank = all detected) | An additional allow-list applied to the F&O phase only, on top of `environmentFilter` and `environmentExclude`. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a **version apply**. Inventory is always collected regardless. LCS types are excluded by default. |
| `finOpsBuildTrainMap` | (blank = built-in map) | Extra live-build-prefix to release-train entries, comma-separated: `10.0.2900=50` (or `10.0.2900=10.0.50`). Added to, and overriding, the built-in map. Malformed entries are ignored with a warning. See "Where the current train comes from" below. |

#### How scope is decided

Each entry returned by `finopsversions` carries Microsoft's `releaseStage`, for example `{"version":"10.0.49.3","releaseStage":"QualityUpdate"}`. That label describes **the build itself** (10.0.49.3 is a quality update on the 10.0.49 train). It does not say whether the build is on the **environment's** current train. The scope therefore combines `releaseStage` with the **release train** (the 3rd version segment, e.g. `48` in `10.0.48.7`):

| `finOpsUpdateScope` | Selects |
|---|---|
| `QualityUpdate` (default, shown as **PQU**) | `releaseStage` is `QualityUpdate` **and** the version's train equals the environment's current train. Example: an environment on 10.0.48 can get 10.0.48.7, never 10.0.49.3. |
| `VersionUpdate` (shown as **version update**) | The version is on the **next** train (current + 1) **and** is staged `GeneralAvailability` or `QualityUpdate`. Example: an environment on 10.0.48 can get 10.0.49.x, never 10.0.50.x in the same run, and never a build staged anything else (for example a preview). |
| `Any` | Every version returned; the numerically highest is selected. No train or stage restriction. |

**Where the current train comes from.** The environment's **live application build**: `applicationVersion` from `finopsproperties`, fetched fresh on every run (for example `10.0.2645.136`). Every PQU of a release shares one build prefix, published by Microsoft in the "Application Version" column of the [release schedule for proactive quality updates](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule). The same page also lists the matching version that `finopsversions` offers, for example:

| PQU train | Application Version (live build) | Provisioning version (offered by `finopsversions`) |
|---|---|---|
| 10.0.47 Release-13 | 10.0.2527.215 | 10.0.47.14 |
| 10.0.48 Release-7 | 10.0.2645.147 | 10.0.48.8 |
| 10.0.49 Release-1 | 10.0.2790.83 | 10.0.49.3 |

Built-in map:

| Build prefix | Release train |
|---|---|
| `10.0.2428` | 10.0.46 |
| `10.0.2527` | 10.0.47 |
| `10.0.2645` | 10.0.48 |
| `10.0.2790` | 10.0.49 |

When a new release ships, read its build prefix from that page and add it, for example `finOpsBuildTrainMap = 10.0.2900=50`. The effective map is printed in the **Effective settings** block of every run.

**Fail-safe rule.** If the current train cannot be determined (no `applicationVersion`, or a build prefix that is not in the map), the apply is **skipped** for that environment, unless the scope is `Any`. The log line names the prefix to add, for example "current release train unknown (build prefix 10.0.2900 is not in the build -> train map; add it to finOpsBuildTrainMap ...)".

**Lower-train guard (every scope, including `Any`).** A version on a lower train than the live build is never applied, whether picked automatically or set in `finOpsTargetVersion`. Microsoft documents that the PPAC version list for an environment only contains versions later than the one installed (see [Update the Finance and Operations Provisioning app](https://learn.microsoft.com/power-platform/admin/unified-experience/tutorial-update-finance-operations-provisioning-app)); this guard enforces the part the script can verify itself.

**Why not the F&O Provisioning App Anchor Solution.** v2.4.2 read the train from the 3rd segment of the Anchor Solution version in Dataverse. Microsoft has confirmed that this record is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API, which is the path this pipeline uses. After the first apply through this pipeline it is permanently stale: the environments moved to 10.0.49.3 in the v2.4.1 incident still read 10.0.48, so v2.4.2 would have skipped every 10.0.49 PQU for them. v2.4.3 uses the Anchor Solution only to detect that F&O is installed, never its version.

Check the "Current train" line in the environment's diagnostic detail when an environment behaves unexpectedly.

> **v2.4.0 and v2.4.1 used `releaseStage` alone.** Because a quality update on a newer train is also staged `QualityUpdate`, `QualityUpdate` scope in those versions could move environments to a new release train. This was confirmed live (10.0.48 environments moved to 10.0.49.3) and fixed in v2.4.2.

> **v2.4.2: train from the Anchor Solution.** It went stale after the first apply through this pipeline, so environments already updated by it were misread. Fixed in v2.4.3 (live build).

> **v2.4.2 and earlier: multi-version lists.** When `finopsversions` returned a bare JSON array with two or more versions, those versions were lost and the environment was reported as "no versions listed". Fixed in v2.4.3.

#### Why apply has exactly one on/off switch

Version apply is implemented against the documented Power Platform API and is gated behind a live route check, so it begins working automatically once the `finopsversions` route is available on your endpoint. That is exactly why it must be a single, explicit, off-by-default variable with nothing else able to enable it: if inventory and apply shared a switch, or if a legacy variable could enable apply as a side effect, then the day the route deploys, anyone who had only enabled the phase for the inventory table would start applying application versions on their next scheduled run without having asked for it.

#### Retired variables

Two earlier names no longer exist: `finOpsInventory` (inventory is unconditional, so a switch for it made no sense) and `updateFinOpsVersion` (an earlier combined switch, superseded by `finOpsApplyVersion`). If either is still present in the variable group, the script ignores it and prints a one-time warning naming exactly which one it found. Remove them; nothing needs to replace them.

## Runtime parameters

Five settings are also exposed as queue-time inputs, so you can override them for a single manual run without editing the variable group:

| Parameter | Values | Effect |
|---|---|---|
| Plan only (`whatIf`) | `useLibraryOrDefault`, `true`, `false` | Overrides the library/default for this run. |
| Try PAC CLI fallback (`usePacFallback`) | `useLibraryOrDefault`, `true`, `false` | Same override behavior. When effectively true, the pipeline installs the PAC CLI on the agent. |
| Apply F&O version (`finOpsApplyVersion`) | `useLibraryOrDefault`, `true`, `false` | **Changes environments.** Enables version apply for this run only. |
| F&O update scope (`finOpsUpdateScope`) | `useLibraryOrDefault`, `QualityUpdate`, `VersionUpdate`, `Any` | Overrides which kind of version is selected, for this run only. |
| F&O target version (`finOpsTargetVersion`) | free text | A specific version for this run. Blank defers to the library value or highest matching scope. |

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
3. **Substring** - any app whose name *contains* the value is matched.

> **Substring matching is deliberately loose, and it is the fallback whenever the value contains no `*`.**
> A long, specific value like `FinanceAndOperationsProvisioning` is safe. A short generic value is not: `sales` would exclude every app with "sales" anywhere in its unique name, localized name, application name or id, which is likely far more than you intended. When in doubt, use the exact unique name, or an explicit wildcard so the intent is visible.

The default is blank. Apps that require the Power Platform Admin Center install wizard are reported under **manual install required** rather than hidden, so you can see what still needs a human. Add them to `appExclude` if you would rather silence them. The F&O Provisioning App Anchor Solution never needs to be added here: it is excluded from the generic install loop entirely, because it is exclusively updated through the dedicated Finance and Operations route.

## Finance and Operations scoping

Two additional controls apply only to the F&O apply phase. Inventory always ignores these and covers every detected F&O environment.

### `finOpsEnvironmentFilter`

An extra allow-list layered on top of the normal environment scoping, applying to apply eligibility only. Useful when you want app updates everywhere but F&O version apply restricted to a subset.

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

This reports what would change across every environment except Production, without changing anything. F&O inventory is included, because it always runs and is read-only.

## Example: inventory everywhere, no version changes

Nothing to configure. This is the default. `finOpsApplyVersion` is `false`, so you get the inventory table and no environment is modified.

## Example: apply only proactive quality updates (PQU) on the dev estate

- `finOpsApplyVersion = true`
- `finOpsUpdateScope = QualityUpdate` (the default; can be omitted)
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
