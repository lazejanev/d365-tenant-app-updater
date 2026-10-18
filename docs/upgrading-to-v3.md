# Upgrading from v2 to v3

v3.0.0 is a major version because **production is now held back by default** and the run is split into Plan and Apply stages. Your variable group keeps working: every v2 setting has the same name and meaning.

## What changes for you

| Area | v2.4.x | v3.0.0 | What to do |
|---|---|---|---|
| Production | Updated with everything else | **Production ring, on by default**: a production environment only takes a version a non-production environment already runs | Nothing, or set `productionRing = false` to keep v2 behaviour |
| Pipeline | One stage, one job | Plan → Apply non-production → Apply production | Update the pipeline YAML (below). The first production apply asks to permit the `d365-production` environment |
| PowerShell | 5.1 for apps, 7 for F&O | **7.2 or later for everything** | Nothing on Microsoft-hosted agents. Self-hosted: install PowerShell 7 |
| App installs | Triggered, not followed | Waits up to 30 minutes and reports each result | Nothing. `waitForInstallsMinutes = 0` restores v2 behaviour |
| Ordering | API order | **A to Z** (environments and apps, Dev2 before Dev10), non-production before production | Nothing |
| Reports | Log only | A colour-coded results board at the end of the log, `summary.md` on the run page (Extensions tab) and `report.json` artifact | Nothing |
| `appExclude` partial matches | Silent | Still work, reported as deprecated | Replace with exact names or `*` wildcards when convenient |
| Sign-in | Client secret | Client secret, or federated (no secret) | Optional: [federated sign-in](setup-azure-devops.md#federated-sign-in-preview) |
| GitHub Actions | Not supported | Supported | Optional: [setup-github.md](setup-github.md) |
| Sync pipeline | Synced `main` | Syncs the **latest GitHub release** by default | Nothing. `syncRef = main` restores v2 behaviour |
| Run result | Always green unless the script crashed | Orange (SucceededWithIssues) when something could not be read or an install failed | Read **Needs attention** in the summary. `failOnIssues = true` fails the Apply stages instead |

## Steps

1. **Get v3.** If you use `sync-from-github.yml`, the next sync brings it. Otherwise copy the release into your repository: `scripts/`, `src/`, `pipelines/`, `azure-pipelines.yml` (and `azure-pipelines-federated.yml` if you want it), `docs/`.
   - `scripts/Update-TenantApps.ps1` now loads the module from `src/`. Copying only the script is not enough.
2. **Keep your pipeline definition.** It points at `azure-pipelines.yml`, which is replaced in place. If you edited it (for example a schedule), re-apply your edit to the new file: the `schedules:` block is in the same place.
3. **Decide on production.** With the default production ring, the first v3 runs update non-production only; production follows on the next run once a non-production environment has each version. Check that the ring is what you expect in the first Plan summary: every environment shows `Production` or `NonProduction`.
   - Environments of PPAC type **Production** are production. Add others with `productionEnvironments` (for example a Sandbox used for training or as pre-production).
   - If you previously excluded production with `environmentExclude`, you can now remove that and let the ring handle it.
4. **Run once with Plan only = true.** Only the Plan stage runs. Read the summary on the Extensions tab.
5. **Run for real.**

## Nothing to change for Finance and Operations

The F&O rules from v2.4.4 are unchanged: inventory always, apply only with `finOpsApplyVersion = true`, the release train from the live build through Microsoft's PQU schedule (downloaded every run), never a lower train, never the Anchor Solution. Production F&O environments now also follow the production ring, and the inventory shows each environment's maintenance window.

## Rolling back

Check out the `v2.4.4` commit (or your previous copy) of `scripts/Update-TenantApps.ps1` and `azure-pipelines.yml`. v3 adds variables but removes none, so the variable group needs no change either way.
