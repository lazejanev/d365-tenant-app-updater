# Release Notes

## v2.0.0 - 2026-08-18

A major simplification of how the pipeline is configured. The behavior is the same proven app-update logic; what changed is that you now configure almost nothing.

### Highlights

- **Only three variables are required:** `ClientId`, `ClientSecret`, `TenantId`.
- **Everything else is optional** with a sensible built-in default. To override any setting, just add a variable with the matching name to the `D365-TenantAppUpdater` group. If it is absent, the default is used. No YAML editing required to tune behavior.
- **Safer override plumbing:** optional values flow through the pipeline `env:` block, so an undefined variable never crashes the run (it stays a harmless literal that the script ignores in favor of the default).
- **Fewer moving parts:** removed `pipelineName`, `agentVmImage`, `jobTimeoutMinutes`, and the endpoint/API variables from the required set. Run name and agent image are fixed in the YAML; API endpoints/versions are script defaults you can still override.
- **Queue-time toggles:** `whatIf` (Plan only) and `usePacFallback` are exposed as runtime dropdowns for one-off runs, in addition to being overridable variables.
- **Defaults refreshed:** `bapApiVersion` default is now `2026-06-01`; App Management uses `2026-05-01-preview`.

### Upgrade notes

- You can safely delete every variable from your group except `ClientId`, `ClientSecret`, `TenantId` - and any you specifically want to override (for example `environmentExclude`, `appExclude`).
- Commit both `azure-pipelines.yml` and `scripts/Update-TenantApps.ps1` together; the two are matched to this model.

---

## v1.4.0 - 2026-08-18

- Wired the real app-update logic: available versions from the Power Platform App Management API, installed versions from Dataverse managed solutions, strict "never downgrade" comparison, install with operation id, and failed-install retry.
- Added App Management endpoint configuration.

## v1.3.0 - 2026-08-18

- Conditional Power Platform CLI install step for the PAC fallback, plus .NET 10 guidance.

## v1.2.0 - 2026-08-18

- `AppExclude` deny-list (pre-seeded with the F&O Provisioning App).
- Smart Custom Install Experience detection: such apps are reported as `manual-required` instead of failing.
- Optional PAC CLI fallback (off by default).

## v1.1.0 - 2026-08-18

- `EnvironmentExclude` deny-list, and `RetryFailedInstalls` on by default.

## v1.0.0 - 2026-08-16

- Initial public release.
