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
| `pollIntervalSec` | `20` | Seconds between install completion polls. |
| `pollTimeoutMin` | `60` | Maximum minutes to wait for an install. |

### Behavior

| Variable | Default | Description |
|---|---|---|
| `dumpDiagnostics` | `true` | Print installed-vs-available diagnostics per environment. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install ended in `InstallFailed`. |
| `whatIf` | `false` | Plan only. Report what would change without changing anything. |
| `usePacFallback` | `false` | Attempt `pac application install` for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | (blank) | Deny-list of app names/ids to always skip. |

### Finance and Operations

| Variable | Default | Description |
|---|---|---|
| `updateFinOpsVersion` | `false` | Master switch for the Finance and Operations phase. When false, F&O environments are still detected and counted but not inspected. |
| `finOpsTargetVersion` | (blank = latest) | A specific F&O application version to apply, for example `10.0.47.5`. Blank selects the highest available version per environment. |
| `finOpsEnvironmentFilter` | (blank = all detected) | An additional allow-list applied to the F&O phase only, on top of `environmentFilter` and `environmentExclude`. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a **version apply**. Inventory is always collected regardless. LCS types are excluded by default. |

## Runtime parameters

Four settings are also exposed as queue-time inputs, so you can override them for a single manual run without editing the variable group:

| Parameter | Values | Effect |
|---|---|---|
| Plan only (`whatIf`) | `useLibraryOrDefault`, `true`, `false` | Overrides the library/default for this run. The sentinel defers to the variable group value or the script default. |
| Try PAC CLI fallback (`usePacFallback`) | `useLibraryOrDefault`, `true`, `false` | Same override behavior. When effectively true, the pipeline installs the PAC CLI on the agent. |
| Also update F&O version (`updateFinOpsVersion`) | `useLibraryOrDefault`, `true`, `false` | Enables or disables the Finance and Operations phase for this run. |
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

| Goal | environmentFilter | environmentExclude | Result |
|---|---|---|---|
| Update everything | (blank) | (blank) | Every Dataverse environment. |
| Update everything except production | (blank) | `Production` | All, but Production is skipped. |
| Update only Dev and Test | `Dev, Test` | (blank) | Only Dev and Test. |
| Update all but never touch UAT | (blank) | `UAT` | All except UAT. |
| Target a list, still protect one | `Dev, Test, UAT` | `UAT` | Dev and Test only. |
| Target one environment by id | `2f3b...id...` | (blank) | Only that environment. |

## App scoping: `appExclude`

Comma-separated application **names, uniqueNames, or ids** that are always skipped on every environment.

Matching supports three forms:

- **Exact** - `msdyn_AppProfileManagerAnchor`
- **Wildcard** - `msdyn_*Anchor`
- **Substring** - `FinanceAndOperations` matches any app whose name contains it

The default is blank. Apps that require the Power Platform Admin Center install wizard are reported under **manual install required** rather than hidden, so you can see what still needs a human. Add them to `appExclude` if you would rather silence them.

## Finance and Operations scoping

Two additional controls apply only to the F&O phase.

### `finOpsEnvironmentFilter`

An extra allow-list layered on top of the normal environment scoping. Useful when you want app updates everywhere but F&O handling on a subset.

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

- `whatIf` = `true`
- `environmentExclude` = `Production`

Everything else omitted. This reports what would change across every environment except Production, without changing anything.

## Example: apps everywhere, F&O inventory only on the dev estate

- `updateFinOpsVersion` = `true`
- `finOpsEnvironmentFilter` = `TPM-DEV01, TPM-DEV02, TPM-DEV03`

Phase 1 still runs against every environment. Phase 2 inspects only the three listed.
