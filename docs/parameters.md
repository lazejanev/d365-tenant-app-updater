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
| `dumpDiagnostics` | `true` | Print installed-vs-available diagnostics per environment. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install ended in `InstallFailed`. |
| `whatIf` | `false` | Plan only. Report what would change without changing anything. |
| `usePacFallback` | `false` | Attempt a PAC CLI install for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | (blank) | Deny-list of app names/ids to always skip. |

### Finance and Operations

Inventory always runs and is read-only. It costs one GET per detected F&O environment and changes nothing, so there is no switch for it. The **only** Finance and Operations variable that changes behaviour is `finOpsApplyVersion`.

| Variable | Default | Description |
|---|---|---|
| `finOpsApplyVersion` | `false` | **The only switch.** Set to `true` to apply a new F&O application version on eligible environments. Everything else in this table only refines what/where an apply targets; none of them enable an apply on their own. |
| `finOpsTargetVersion` | (blank = latest) | A specific F&O application version to apply, for example `10.0.47.5`. Blank selects the highest available version per environment. Only used when `finOpsApplyVersion` is `true`. |
| `finOpsEnvironmentFilter` | (blank = all detected) | An additional allow-list applied to the F&O phase only, on top of `environmentFilter` and `environmentExclude`. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a **version apply**. Inventory is always collected regardless. LCS types are excluded by default. |

#### Why apply is a single, off-by-default switch

Version discovery and apply are implemented against the documented Power Platform API and are gated behind a live route check, so they begin working automatically once the route is available on your endpoint.

That is exactly why `finOpsApplyVersion` must be a single, explicit, off-by-default switch, with no other variable able to turn it on. If inventory and apply shared a switch, or if a legacy variable could enable apply as a side effect, then the day the route deploys, anyone whose configuration merely enabled the F&O phase for the inventory table would start applying application versions on their next scheduled run without having asked for it. With one variable and one meaning, that cannot happen: apply only ever runs when `finOpsApplyVersion = true` is set explicitly, in the variable group or as a queue-time parameter.

#### Retired variables

Two earlier names no longer exist: `finOpsInventory` (inventory is unconditional, so a switch for it made no sense) and `updateFinOpsVersion` (an earlier combined switch). If either is still present in the variable group, the script ignores it and prints a one-time warning naming exactly which one it found. Remove them; nothing needs to replace them, since inventory always runs and `finOpsApplyVersion` is the only apply trigger.

## Runtime parameters

Four settings are also exposed as queue-time inputs, so you can override them for a single manual run without editing the variable group:

| Parameter | Values | Effect |
|---|---|---|
| Plan only (`whatIf`) | `useLibraryOrDefault`, `true`, `false` | Overrides the library/default for this run. The sentinel defers to the variable group value or the script default. |
| Try PAC CLI fallback (`usePacFallback`) | `useLibraryOrDefault`, `true`, `false` | Same override behavior. When effectively true, the pipeline installs the PAC CLI on the agent. |
| Apply F&O version (`finOpsApplyVersion`) | `useLibraryOrDefault`, `true`, `false` | **Changes environments.** Enables version apply for this run only. |
| F&O target version (`finOpsTargetVersion`) | free text | A specific version for this run. Blank defers to the library value or latest available. |

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

The default is blank. Apps that require the Power Platform Admin Center install wizard are reported under **manual install required** rather than hidden, so you can see what still needs a human. Add them to `appExclude` if you would rather silence them.

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

LCS managed environments are excluded deliberately. Their application updates are driven through Lifecycle Services, not the Power Platform API, so attempting an apply would be incorrect. If you ever need to change the list, set the variable explicitly.

## Example: safe production-protected preview

Variable group:

- `whatIf = true`
- `environmentExclude = Production`

Everything else omitted. This reports what would change across every environment except Production, without changing anything. F&O inventory is included, because it always runs and is read-only.

## Example: inventory everywhere, no version changes

Nothing to configure. This is the default. `finOpsApplyVersion` is `false`, so you get the inventory table and no environment is modified.

## Example: apply versions on the dev estate only

- `finOpsApplyVersion = true`
- `finOpsEnvironmentFilter = TPM-DEV01, TPM-DEV02, TPM-DEV03`

Phase 1 still runs against every environment. Inventory is reported for every F&O environment. Version apply is attempted only on the three listed, and only if their deployment type is in `finOpsDeploymentTypes`.

Run this with `whatIf = true` first.
