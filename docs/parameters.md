# Parameters and variables

This project is fully variable driven. Nothing is hardcoded in the YAML or the script. Every value comes from a single Azure DevOps Library variable group named **`D365-TenantAppUpdater`**. Runtime parameters only exist to let an operator override a stored default for one manual run.

## Environment scoping: how filter and exclude work

There are two independent controls for choosing which environments get updated. They work together.

### `environmentFilter` - the allow-list

An allow-list of environment **names or ids**, comma separated. If you set it, the pipeline processes **only** those environments and skips everything else.

- Blank -> process **all** environments on the tenant.
- `Dev, Test` -> process **only** Dev and Test.
- Matching is case-insensitive and works on either the environment **display name** or its **id**.

### `environmentExclude` - the deny-list (exempt)

A deny-list of environment **names or ids**, comma separated. Any environment on it is **always skipped**, even if it would otherwise match the filter. This is the safe way to protect production or any environment you never want touched.

- Blank -> nothing is exempted.
- `Production, DR` -> those two are never updated, no matter what.

### The combined rule

An environment is processed when:

```
(environmentFilter is blank OR the environment matches environmentFilter)
AND
the environment does NOT match environmentExclude
```

The exclude list always wins over the filter.

### Worked examples

| Goal | environmentFilter | environmentExclude | Result |
|---|---|---|---|
| Update everything | (blank) | (blank) | Every environment on the tenant. |
| Update everything except production | (blank) | `Production` | All environments, but Production is skipped. |
| Update only Dev and Test | `Dev, Test` | (blank) | Only Dev and Test. |
| Update all sandboxes but never touch UAT | (blank) | `UAT` | All environments except UAT. |
| Target a list, still protect one of them | `Dev, Test, UAT` | `UAT` | Dev and Test only. UAT is excluded even though it is in the filter. |
| Target one environment by id | `2f3b...id...` | (blank) | Only that environment. |

## App scoping: `appExclude`

A deny-list of application **names or ids**, comma separated, that are **always skipped on every environment**. Use it for apps that cannot be installed by this API.

- Matches on either the application **name** (for example `msdyn_FinanceAndOperationsProvisioningApp`) or its **id**.
- Pre-seeded default: `msdyn_FinanceAndOperationsProvisioningApp` (the F&O Provisioning App / Anchor Solution).

### Why this exists: Custom Install Experience apps

Some first-party apps use a guided Single Page Application install wizard in the Power Platform Admin Center. The BAP install API rejects them with:

```
StatusCode: 400
"This application utilizes a Custom Install Experience through a Single Page
Application. Install for such apps is not supported by this API. Please utilize
the Power Platform Admin Center to initiate the install and configuration experience."
```

This is by design and cannot be fixed with permissions. The script handles it in three ways:

1. Any app in `appExclude` is skipped up front (action `skipped-excluded`).
2. If an app not on the list hits that specific 400, it is classified as `manual-required` instead of `failed`, so retry does not hammer it every run. These are listed in a dedicated "Manual install required (use PPAC)" summary.
3. Optionally (`usePacFallback`), the script attempts `pac application install` as a best-effort fallback before giving up.

## PAC CLI fallback: `usePacFallback`

When `true`, an app rejected by the API for a custom install is retried using the Power Platform CLI:

```
pac auth create --applicationId <ClientId> --clientSecret <secret> --tenant <TenantId>
pac application install --environment-id <env> --application-name <app>
```

Notes and caveats:

- **Off by default.** Enable it only after you have tested it.
- When it is on, the pipeline runs a step that installs the CLI on the agent automatically. See below.
- The PAC CLI calls the same programmability API family, so for true SPA-install apps it may still be blocked. Treat it as best effort, not a guaranteed fix. When it also fails, the app falls back to `manual-required`.

### The Power Platform CLI on the agent

- The pipeline installs the CLI only when the fallback is on, using the modern .NET tool package **`Microsoft.PowerApps.CLI.Tool`**:

  ```
  dotnet tool install --global Microsoft.PowerApps.CLI.Tool --version $(pacCliVersion)
  ```

- **.NET 10 requirement.** Recent CLI tool versions (2.11.x) target **.NET 10.0**, so the agent needs a compatible .NET SDK. Microsoft-hosted `windows-latest` agents generally have it; on a self-hosted agent, make sure .NET 10 is installed.
- **Version pinning.** Set the `pacCliVersion` variable to pin a version (for example `2.11.2`) for reproducible runs, or leave it blank to always install the latest.
- **Package name.** Use `Microsoft.PowerApps.CLI.Tool` (the .NET tool). The older `Microsoft.PowerApps.CLI` package is the MSI/build-tools style and is not what this pipeline uses.

## Variable group: `D365-TenantAppUpdater`

Create this group under **Pipelines > Library** and add every variable below.

### Credentials

| Variable | Secret | Example | Description |
|---|---|---|---|
| `ClientId` | No | `<application-client-id>` | Entra ID application (client) id of the service principal. |
| `ClientSecret` | Yes | `<secret-value>` | Client secret value. Always mark as secret. |
| `TenantId` | No | `<directory-tenant-id>` | Entra ID directory (tenant) id. |

### Endpoints and API configuration

| Variable | Example | Description |
|---|---|---|
| `authority` | `https://login.microsoftonline.com/$(TenantId)/oauth2/v2.0/token` | Token endpoint. You may reference `$(TenantId)` inside the value. |
| `bapResource` | `https://api.bap.microsoft.com/` | BAP admin API resource, used to build the token scope. |
| `bapApiRoot` | `https://api.bap.microsoft.com` | BAP admin API base URL. |
| `bapApiVersion` | `2021-04-01` | API version appended to BAP requests. |
| `powerPlatformScope` | `https://api.powerplatform.com/.default` | Power Platform API scope for app inventory. |
| `pollIntervalSec` | `20` | Seconds between install completion polls. |
| `pollTimeoutMin` | `60` | Maximum minutes to wait for an install to complete. |

### Behavior defaults

These are the values used when a runtime parameter is left at `fromLibrary`.

| Variable | Recommended | Description |
|---|---|---|
| `dumpDiagnostics` | `true` | Default for printing the installed versus available table. |
| `retryFailedInstalls` | `true` | Default for retrying previously failed installs. On by default. |
| `whatIf` | `false` | Default for plan-only mode. |
| `environmentFilter` | empty | Default allow-list. Blank means all environments. |
| `environmentExclude` | e.g. `Production` | Default deny-list. Environments here are always skipped. |
| `appExclude` | `msdyn_FinanceAndOperationsProvisioningApp` | Default app deny-list. Apps here are always skipped (custom-install apps). |
| `usePacFallback` | `false` | Default for the PAC CLI fallback. Off by default. |

### Pipeline and agent

| Variable | Example | Description |
|---|---|---|
| `pipelineName` | `d365-tenant-app-updater` | Used to build the run name. |
| `agentVmImage` | `windows-latest` | Agent image for the pool. |
| `jobTimeoutMinutes` | `180` | Job timeout in minutes. |
| `pacCliVersion` | `2.11.2` | Power Platform CLI version to install for the fallback. Blank installs latest. |

## Runtime parameters

Prompted when you run the pipeline manually. Each defaults to `fromLibrary`, which means "use the value stored in the variable group". Override for a single run without editing the library.

| Parameter | YAML name | Values | Description |
|---|---|---|---|
| Dump diagnostics | `dumpDiagnostics` | `fromLibrary`, `true`, `false` | Override the diagnostic dump for this run. |
| Retry failed installs | `retryFailedInstalls` | `fromLibrary`, `true`, `false` | Override retry behavior for this run. Library default is on. |
| Plan only | `whatIf` | `fromLibrary`, `true`, `false` | Override plan-only mode for this run. |
| Environment filter | `environmentFilter` | free text or `fromLibrary` | Override the allow-list for this run. |
| Environment exclude | `environmentExclude` | free text or `fromLibrary` | Override the deny-list for this run. |
| App exclude | `appExclude` | free text or `fromLibrary` | Override the app deny-list for this run. |
| Use PAC fallback | `usePacFallback` | `fromLibrary`, `true`, `false` | Override the PAC CLI fallback for this run. |

## How override resolution works

For each flag the script receives two values: the runtime parameter and the library default (passed as `-Default...`). The rule:

- If the runtime parameter is blank or `fromLibrary`, the library value wins.
- Otherwise the runtime parameter wins.

This keeps the variable group as the single source of truth, while still allowing a one-off manual override.

## Script parameters (reference)

`scripts/Update-TenantApps.ps1` receives all of the above as explicit parameters. It hardcodes nothing.

| Parameter | Source |
|---|---|
| `-ClientId`, `-ClientSecret`, `-TenantId` | Credentials variables |
| `-Authority`, `-BapResource`, `-BapApiRoot`, `-BapApiVersion`, `-PowerPlatformScope`, `-PollIntervalSec`, `-PollTimeoutMin` | Endpoint variables |
| `-DumpDiagnostics`, `-RetryFailedInstalls`, `-WhatIf`, `-EnvironmentFilter`, `-EnvironmentExclude`, `-AppExclude`, `-UsePacFallback` | Runtime parameters |
| `-DefaultDumpDiagnostics`, `-DefaultRetryFailedInstalls`, `-DefaultWhatIf`, `-DefaultEnvironmentFilter`, `-DefaultEnvironmentExclude`, `-DefaultAppExclude`, `-DefaultUsePacFallback` | Behavior default variables |

## Example: safe production-protected run, plan only

- Dump diagnostics: `fromLibrary`
- Retry failed installs: `fromLibrary` (on)
- Plan only: `true`
- Environment filter: `fromLibrary` (all)
- Environment exclude: `Production`

This reports what would change across every environment except Production, without installing anything.
