# Parameters and variables

The configuration model is simple: **three variables are required, everything else is optional with a built-in default.** To override a default, add a variable with the matching name to the `D365-TenantAppUpdater` variable group. If the variable is absent, the script uses its default. You never edit the YAML to change behavior.

## How resolution works

For each optional setting the script resolves the value in this order:

1. An explicit script parameter (used when running the script by hand).
2. The matching environment variable (how the pipeline passes overrides from the variable group).
3. The built-in default.

An unexpanded Azure DevOps macro (for example `$(bapApiVersion)`, which is what you get when a variable is not defined in the group) is treated as "not set", so the default applies. Placeholder text like `(empty)`, `(none)`, or `(all)` is also treated as blank.

## Required variables

| Variable | Secret | Description |
|---|---|---|
| `ClientId` | No | Entra ID application (client) id of the service principal. |
| `ClientSecret` | **Yes** | Client secret value. Always mark as secret. |
| `TenantId` | No | Entra ID directory (tenant) id. |

## Optional variables and their defaults

Add any of these to the variable group only if you want to override the default.

### Endpoints and API configuration

| Variable | Default | Description |
|---|---|---|
| `authority` | `https://login.microsoftonline.com/<TenantId>/oauth2/v2.0/token` | Token endpoint. Built from `TenantId` when not set. |
| `bapApiRoot` | `https://api.bap.microsoft.com` | BAP admin API base URL. The BAP token scope is derived as `<bapApiRoot>/.default`. |
| `bapApiVersion` | `2026-06-01` | API version for the environments list. |
| `ppApiRoot` | `https://api.powerplatform.com` | Power Platform App Management base URL. |
| `powerPlatformScope` | `https://api.powerplatform.com/.default` | Token scope for App Management. |
| `appManagementApiVersion` | `2026-05-01-preview` | API version for App Management calls. |
| `pollIntervalSec` | `20` | Seconds between install completion polls. |
| `pollTimeoutMin` | `60` | Maximum minutes to wait for an install. |

### Behavior

| Variable | Default | Description |
|---|---|---|
| `dumpDiagnostics` | `true` | Print installed-vs-available diagnostics per environment. |
| `retryFailedInstalls` | `true` | Retry apps whose previous install ended in `InstallFailed`. |
| `whatIf` | `false` | Plan only. Report what would change without installing. |
| `usePacFallback` | `false` | Attempt `pac application install` for custom-install apps. |
| `environmentFilter` | (blank = all) | Allow-list of environment names/ids to process. |
| `environmentExclude` | (blank = none) | Deny-list of environment names/ids to always skip. |
| `appExclude` | `msdyn_FinanceAndOperationsProvisioningApp` | Deny-list of app names/ids to always skip. |

## Runtime parameters

Two settings are also exposed as queue-time dropdowns, so you can override them for a single manual run without editing the variable group:

| Parameter | Values | Effect |
|---|---|---|
| Plan only (`whatIf`) | `useLibraryOrDefault`, `true`, `false` | `true`/`false` override the library/default for this run; the sentinel defers to the variable group value or the script default. |
| Try PAC CLI fallback (`usePacFallback`) | `useLibraryOrDefault`, `true`, `false` | Same override behavior. When effectively `true`, the pipeline installs the PAC CLI on the agent. |

## Environment scoping: how filter and exclude work

Two independent controls decide which environments run. They work together.

### `environmentFilter` - the allow-list

Comma-separated environment **names or ids**. If set, only those environments are processed; everything else is skipped. Blank means all. Matching is case-insensitive on either the display name or the id.

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

Comma-separated application **names, uniqueNames, or ids** that are always skipped on every environment. Pre-seeded with `msdyn_FinanceAndOperationsProvisioningApp` (the F&O Provisioning App), which requires the PPAC Custom Install Experience and cannot be installed by the API.

## Example: safe production-protected preview

Variable group:

- `whatIf` = `true`
- `environmentExclude` = `Production`

Everything else omitted (defaults apply). This reports what would change across every environment except Production, without installing anything.

## Example: newest API surface

If you want to pin the newest API versions explicitly:

- `bapApiVersion` = `2026-06-01`
- `appManagementApiVersion` = `2026-05-01-preview`

These are already the defaults, so you only need to set them if a newer version ships and you want to move to it without changing code.
