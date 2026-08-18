# d365-tenant-app-updater

Automatically update all Dynamics 365 first-party apps across an entire tenant, from a single Azure DevOps pipeline.

If you run Dynamics 365 across more than a couple of environments, you know the ritual. Log into the admin center, open one environment, check for app updates, install, wait, then repeat for the next environment, and the next, and the next. Multiply that by every environment on the tenant and every first-party app, and you have lost an afternoon you are never getting back.

This project turns that manual chore into a hands-off, repeatable process. A service principal authenticates non-interactively, discovers every environment on the tenant, compares installed versus available app versions, installs the updates that are needed, and retries the ones that previously failed.

> Community project. This is not an official Microsoft tool. Test it in a non-production tenant or environment before you point it at anything that matters.

## What it does

- Authenticates as a service principal. No interactive logins, no babysitting.
- Discovers every environment on the tenant through the Power Platform and BAP admin APIs.
- Compares installed versus available versions for each app, on each environment.
- Installs the updates that are actually needed, and retries the ones that previously failed instead of quietly skipping them.
- Lets you scope runs with an allow-list and protect environments with a deny-list.
- Handles apps that require the PPAC Custom Install Experience without failing the run.
- Prints a clear installed versus available diagnostic so you can verify everything at a glance.

## Why it exists

Tenant-wide app maintenance does not scale by hand. The effort grows with every new environment and every new app. This pipeline scales the same whether you have 3 environments or 30, which is exactly where it saves customers and partners the most time. Let the platform and the automation handle the repetitive work, so the humans focus on the problems that actually need a brain.

## How it works

```
Azure DevOps pipeline
        |
        v
  scripts/Update-TenantApps.ps1
        |
        |  1. Acquire Power Platform + BAP tokens (service principal, client credentials)
        |  2. GET /providers/Microsoft.BusinessAppPlatform/scopes/admin/environments
        |  3. Apply allow-list (filter) and deny-list (exclude)
        |  4. For each environment: list installed apps and available updates
        |  5. Compare versions, build an update plan (respecting appExclude)
        |  6. Install required updates, poll for completion
        |  7. Retry previously failed installs (on by default)
        |  8. Handle custom-install apps (manual-required, or PAC CLI fallback)
        |  9. Print installed vs available diagnostic and summary
        v
   Updated tenant
```

## Prerequisites

- An Azure DevOps organization and project, with permission to create pipelines and service connections.
- An Entra ID (Azure AD) app registration (service principal) with a client secret.
- Power Platform Administrator rights in the target tenant (needed once, to register the service principal as a management application).
- A self-hosted or Microsoft-hosted Windows agent with PowerShell 7.
- For the optional PAC CLI fallback: a .NET SDK compatible with the CLI (recent versions target .NET 10). The pipeline installs the CLI for you when the fallback is enabled.

## Setup

Full step by step is in [docs/setup.md](docs/setup.md). In short:

1. Create the Entra ID app registration and a client secret.
2. Register the service principal as a Power Platform management application (see [docs/permissions.md](docs/permissions.md)).
3. Grant the required API permissions and admin consent.
4. Create the `D365-TenantAppUpdater` variable group with the values in [docs/parameters.md](docs/parameters.md).
5. Add the pipeline from `azure-pipelines.yml` and run it.

### Fully variable driven

Nothing is hardcoded. The YAML and the PowerShell script contain no ids, secrets, endpoints, api versions, or customer names. Every value is sourced from the `D365-TenantAppUpdater` Library variable group. Runtime parameters exist only to override a stored default for a single manual run, using a `fromLibrary` sentinel that falls back to the group value.

## Required permissions

The permissions setup is the single most important part, and the most common reason the pipeline fails on a fresh tenant. Read [docs/permissions.md](docs/permissions.md) before your first run. It covers:

- Registering the service principal with `New-PowerAppManagementApp`.
- The API permissions the app registration needs.
- The application-user-plus-role requirement in each target environment's Dataverse.

## How to run

- Manual: run the pipeline from Azure DevOps and provide the runtime parameters.
- Scheduled: enable the cron schedule in `azure-pipelines.yml` to keep the tenant continuously up to date.

## Environment scoping

Two independent controls decide which environments are updated:

- `environmentFilter` - allow-list. Only these environments are processed. Blank means all.
- `environmentExclude` - deny-list. These environments are always skipped, even if they match the filter. Use it to protect production.

Full explanation and worked examples are in [docs/parameters.md](docs/parameters.md).

## Parameters

See [docs/parameters.md](docs/parameters.md) for the full list. The most used ones:

| Parameter | Default | Purpose |
|---|---|---|
| `DumpDiagnostics` | `true` | Print the installed vs available version table for every environment. |
| `RetryFailedInstalls` | `true` | Retry installs that previously ended in a failed state. On by default. |
| `EnvironmentFilter` | empty | Allow-list. Limit the run to a subset of environments. |
| `EnvironmentExclude` | empty | Deny-list. Always skip these environments (e.g. Production). |
| `AppExclude` | F&O Provisioning App | Deny-list. Always skip these apps (custom-install apps the API cannot handle). |
| `UsePacFallback` | `false` | Try `pac application install` for custom-install apps. Best effort, off by default. |
| `WhatIf` | `false` | Plan only. List what would be updated without installing anything. |

### Custom Install Experience apps

Some first-party apps (for example the Finance and Operations Provisioning App) use a guided install wizard in the Power Platform Admin Center and cannot be installed by the API. The pipeline skips these by name via `AppExclude` (pre-seeded with the F&O Provisioning App), detects the API's "not supported by this API" response and reports those apps as `manual-required` rather than failing, and can optionally attempt a PAC CLI fallback. See [docs/parameters.md](docs/parameters.md) for details.

## Known limitations and roadmap

- Targets Dynamics 365 first-party apps. It does not manage third-party or ISV solutions.
- Version availability depends on what the tenant's release channel exposes.
- The PAC CLI fallback uses the same programmability API family, so true SPA-install apps may still require the PPAC UI.
- Roadmap ideas: per-environment approval gates, Teams or email summary notification, parallel installs across environments, and a dry-run report artifact.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).

## Author

Laze Janev - Dynamics 365 Solution Architect and Microsoft MVP (AI ERP), founder of Janev Consulting.

- LinkedIn: https://www.linkedin.com/in/lazejanev/
- Microsoft MVP profile: https://mvp.microsoft.com/en-US/mvp/profile/5663c435-4e8a-4c28-8d49-7e76a6cfc4c4
- Speaker profile: https://sessionize.com/laze-janev/

If this saved you an afternoon, a star on the repo is appreciated, and I would love to hear how you use it.
