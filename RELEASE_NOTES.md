# Release Notes

## v2.2.0 - 2026-09-19

Adds Finance and Operations environment inventory, and implements F&O application version updates.

### Highlights

- **F&O inventory, tenant wide.** For every environment where Finance and Operations is installed, the run reports application version, platform version, deployment type, AOS counts, demo dataset and scheduled actions, then prints a consolidated table. Version drift across a dev estate becomes obvious at a glance.
- **Version update implemented.** Discovery and apply are built against the documented Power Platform routes and are gated behind a live route check.
- **LCS environments are inventoried, never version-updated.** `LCSSandbox` and `LCSProduction` are excluded from version apply by design, because Lifecycle Services drives their updates. Controlled by the new `finOpsDeploymentTypes` variable.
- **No CLI dependency for F&O.** The phase calls the REST API directly. The Power Platform CLI is installed only when the optional app-install fallback is enabled.
- **Better error classification.** Apps that require the Power Platform Admin Center wizard are now correctly reported as manual install required instead of being counted as failures.

### New variables

| Variable | Default | Purpose |
|---|---|---|
| `updateFinOpsVersion` | `false` | Master switch for the F&O phase. |
| `finOpsTargetVersion` | blank | Specific version to apply. Blank selects the latest available. |
| `finOpsEnvironmentFilter` | blank | Extra allow-list for the F&O phase only. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Deployment types eligible for a version apply. |
| `finOpsApiVersion` | `2024-10-01` | API version for the F&O routes. |

### Known limitation: the version routes

Version discovery uses the documented route:

```text
GET {ppApiRoot}/dynamics/environments/{environmentId}/finopsversions?api-version=2024-10-01
```

At the time of writing, on a tenant in West Europe using an app-only token, `finopsproperties` returns HTTP 200 with full data while `finopsversions` returns HTTP 404 `RouteNotFound`. Because the sibling route succeeds on the identical call shape, the token, the environment id and the api-version are all accepted; the versions leaf simply does not resolve on that endpoint. This was observed consistently across 11 environments spanning two deployment types.

Practical effect:

- Inventory works today and is the useful capability in this release.
- Version apply does not run while the route returns `RouteNotFound`. It is reported factually per environment and is not counted as a failure.
- No code change will be needed. When the route becomes available on your endpoint, the next run uses it automatically.

### Upgrade notes

- The F&O phase is **off by default**. Add `updateFinOpsVersion` = `true` to enable it.
- `appExclude` now defaults to empty. If you previously relied on the built-in default to hide the F&O Provisioning App, set the variable explicitly.
- Run with `whatIf` = `true` first.

---

## v2.0.0 - 2026-08-18

A major simplification of how the pipeline is configured.

- Only three variables are required: `ClientId`, `ClientSecret`, `TenantId`.
- Everything else is optional with a sensible built-in default, overridable by adding a variable with the matching name.
- Optional values flow through the pipeline `env:` block, so an undefined variable never crashes the run.
- Removed `pipelineName`, `agentVmImage` and `jobTimeoutMinutes` from the variable set.

---

## v1.4.0 - 2026-08-18

Wired the real app-update logic: available versions from the App Management API, installed versions from Dataverse managed solutions, strict never-downgrade comparison, install with operation id, and failed-install retry.

## v1.2.0 - 2026-08-18

`AppExclude` deny-list, Custom Install Experience detection, and the optional PAC CLI fallback.

## v1.1.0 - 2026-08-18

`EnvironmentExclude` deny-list, and `RetryFailedInstalls` on by default.

## v1.0.0 - 2026-08-16

Initial public release.
