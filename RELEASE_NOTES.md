# Release Notes

## v2.3.0 - 2026-09-19

Reduces Finance and Operations to a single variable, removes two settings that did nothing, and independently confirms the version-route gap through a second method.

### Why this release exists

v2.2.0 shipped F&O version apply implemented and gated behind a live route check, so it would start working automatically when the `finopsversions` route became available. That is still the right engineering decision.

During this release, two designs for how to expose that switch were tried and both were rejected: a single combined variable (the original `updateFinOpsVersion`, enabling inventory and apply together), and a two-variable split (`finOpsInventory` + `finOpsApplyVersion`). Both share the same flaw: more than one variable, or one variable meaning two things, creates a path where a variable group that was only ever configured for the inventory table starts applying application versions the day the route deploys, without anyone having asked for that.

The fix settled on for v2.3.0: inventory is unconditional and has no variable at all, since it is one read-only GET per F&O environment and costs nothing. `finOpsApplyVersion` is the **only** Finance and Operations variable, defaults to `false`, and is the only thing that can ever trigger an apply.

### Highlights

- **One Finance and Operations variable.** `finOpsApplyVersion`, default `false`. Also a queue-time runtime parameter.
- **Inventory is unconditional.** It always runs, is always read-only, and has no switch to turn it off.
- **A loud warning when apply is on.** The effective settings block prints a warning that eligible environments will be moved to a new application version.
- **Transport failures read correctly.** A request that never received an HTTP response used to surface as `HTTP -1`. It now says so plainly and includes the underlying detail.
- **PowerShell 7 guard.** The F&O phase uses `-SkipHttpErrorCheck`, which is PowerShell 7 only. Under Windows PowerShell 5.1 the phase is skipped with a clear message rather than failing obscurely. Phase 1 is unaffected.
- **Two dead settings removed.** `pollIntervalSec` and `pollTimeoutMin` were resolved and never used. No polling loop existed, yet the docs described them as real behaviour.
- **Independent reproduction of the route gap.** The `finopsversions` and `apply` route failures were confirmed a second way, via Microsoft's own `pac dynamics get-fin-ops-versions` and `apply-fin-ops-version` CLI commands. Both construct and issue the identical request URL as the script's raw REST calls, and both receive the identical `RouteNotFound` response. This rules out any possibility that the script's own REST construction was the problem.

### Variable changes

| Variable | Default | Status | Purpose |
|---|---|---|---|
| `finOpsApplyVersion` | `false` | **The only F&O switch** | Apply F&O application versions. Changes environments. |
| `finOpsTargetVersion` | blank | Unchanged | Specific version to apply. Blank selects the latest available. |
| `finOpsEnvironmentFilter` | blank | Unchanged | Extra allow-list for the apply phase only. Inventory ignores it. |
| `finOpsDeploymentTypes` | `UnifiedDeveloper,UnifiedSandbox,UnifiedProduction` | Unchanged | Deployment types eligible for a version apply. |
| `finOpsApiVersion` | `2024-10-01` | Unchanged | API version for the F&O routes. |
| `finOpsInventory` | - | **Retired** | Never existed as a meaningful switch; inventory is unconditional. Ignored if present, with a warning. |
| `updateFinOpsVersion` | - | **Retired** | Superseded by `finOpsApplyVersion`. Ignored if present, with a warning. Not repurposed to mean anything. |
| `pollIntervalSec` | - | **Removed** | Never read. No polling loop existed. |
| `pollTimeoutMin` | - | **Removed** | Never read. No polling loop existed. |

### Upgrade notes

- **If your variable group has `updateFinOpsVersion` or `finOpsInventory`, delete both.** Inventory runs unconditionally regardless, so removing them changes nothing you see, other than silencing the one-time warning.
- **If you want version apply, set `finOpsApplyVersion = true` explicitly.** Nothing else can turn it on: not a default, not a legacy variable, not the platform route becoming available.
- **If you had `pollIntervalSec` or `pollTimeoutMin` in your variable group**, remove them. They never had any effect.
- Run with `whatIf = true` first.

### Documentation

README, `docs/parameters.md`, `docs/setup.md`, `docs/permissions.md` and `CONTRIBUTING.md` were all updated to describe the single-variable model consistently. Notable corrections:

- The `azure-pipelines.yml` header no longer asserts that a 404 means the environment is not a PPAC-managed F&O environment. That hypothesis was disproved by diagnostics and contradicted the project's own rule about reporting what the API returned. It now also documents the `apply` sub-route failure and the CLI-based confirmation.
- `docs/permissions.md` no longer points at an unnamed "matching" API permission. It states what was verified: the management application registration was sufficient on its own.
- `appExclude` substring matching is documented as the loose fallback it is, with a warning that short values match broadly.
- `CONTRIBUTING.md` carries the project's non-negotiable invariants, including one specific to this release: exactly one variable may ever enable a destructive F&O capability, and a retired variable name is never quietly repurposed.
- The `sync-from-github.yml` schedule is weekly. The inline comment and the README both previously said hourly.

### Known limitation: the version routes

On a tenant in West Europe using an app-only token, `finopsproperties` returns HTTP 200 with full data, while both `finopsversions` and `finopsversions/{version}/apply` return HTTP 404 `RouteNotFound`. Because the sibling route succeeds on the identical call shape, the token, the environment id and the api-version are all accepted; the versions leaf and its apply sub-route simply do not resolve on that endpoint.

This was confirmed via two independent methods: hand-built REST calls, and Microsoft's own `pac dynamics` CLI. Both construct and issue the identical request URL and receive the identical response, ruling out client-side request construction as the cause.

Practical effect:

- Inventory works today and always runs.
- Version apply does not run while the route returns `RouteNotFound`. It is reported factually per environment and is not counted as a failure.
- No code change will be needed. When the route becomes available on your endpoint, the next run **with `finOpsApplyVersion = true`** uses it automatically.

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

### Upgrade notes

- The F&O phase is **off by default**. Add `updateFinOpsVersion = true` to enable it.
- `appExclude` now defaults to empty. If you previously relied on the built-in default to hide the F&O Provisioning App, set the variable explicitly.
- Run with `whatIf = true` first.

## v2.0.0 - 2026-08-18

A major simplification of how the pipeline is configured.

- Only three variables are required: `ClientId`, `ClientSecret`, `TenantId`.
- Everything else is optional with a sensible built-in default, overridable by adding a variable with the matching name.
- Optional values flow through the pipeline `env:` block, so an undefined variable never crashes the run.
- Removed `pipelineName`, `agentVmImage` and `jobTimeoutMinutes` from the variable set.

## v1.4.0 - 2026-08-18

Wired the real app-update logic: available versions from the App Management API, installed versions from Dataverse managed solutions, strict never-downgrade comparison, install with operation id, and failed-install retry.

## v1.2.0 - 2026-08-18

`AppExclude` deny-list, Custom Install Experience detection, and the optional PAC CLI fallback.

## v1.1.0 - 2026-08-18

`EnvironmentExclude` deny-list, and `RetryFailedInstalls` on by default.

## v1.0.0 - 2026-08-16

Initial public release.
