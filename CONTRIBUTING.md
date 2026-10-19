# Contributing

Thanks for your interest in improving this project. Issues and pull requests are welcome.

## Ground rules

- Be respectful and constructive. This is a community project maintained in spare time.
- Never commit secrets. No tenant IDs, environment IDs, application or client IDs, secrets, org URLs, environment names, or customer names. The only required inputs are provided at run time through the variable group.
- Keep it generic. Nothing in this repo should be tied to a specific customer, tenant, or environment. Use placeholders such as `Dev01` in examples.

## Reporting issues

When you open an issue, include:

- What you expected to happen and what actually happened.
- The relevant part of the pipeline log, with all IDs, secrets, environment names and customer names redacted.
- Your agent type (Microsoft-hosted or self-hosted) and PowerShell version.
- Which variables you set in the group (names only, values redacted).

## How the code is laid out (v3)

```
scripts/Update-TenantApps.ps1          thin entry point (parameters -> module)
scripts/sync_keep_settings.py          keeps local pipeline settings when sync-from-github.yml resets
src/D365TenantAppUpdater/
  D365TenantAppUpdater.psd1            ModuleVersion: the ONLY place the version lives
  D365TenantAppUpdater.psm1            loads the files below in a fixed order
  Util.ps1                             small helpers (Get-Count, sorting, ...)
  Host.ps1                             the ONLY file that knows Azure DevOps vs GitHub
  Settings.ps1                         defaults and setting resolution
  Http.ps1                             one HTTP helper (never throws, retries GET on 429/503)
  Auth.ps1                             client secret and federated sign-in, token cache
  Versions.ps1                         version compare, F&O version list, release map
  Discovery.ps1                        environments and rings
  Apps.ps1                             phase 1: collect and decide
  FinOps.ps1                           phase 2: collect and decide
  Plan.ps1                             collect -> plan, plan.json
  Apply.ps1                            execute, re-validate, trigger (optional wait for installs)
  Report.ps1                           results board, summary.md, report.json
  Main.ps1                             Invoke-D365TenantAppUpdate
tests/                                 Pester 5 (Unit, Scenario), fake tenant in TestHelpers.ps1
docs/architecture.md                   diagrams; sources in docs/diagrams, images in docs/images
azure-pipelines.yml                    Azure DevOps pipeline (root: existing pipelines point here)
sync-from-github.yml                   Azure DevOps sync from GitHub (root: existing pipelines point here)
pipelines/azure-pipelines-federated.yml   Azure DevOps pipeline without a secret (preview)
pipelines/templates/stages.yml         the three stages, shared by both Azure DevOps pipelines
pipelines/templates/run-updater.yml    the steps of one job
.github/workflows/                     GitHub workflow, CI, release
```

Rules that keep it that way:

- Nothing outside `Host.ps1` writes `##vso[...]`, `##[group]`, `::warning::` or touches `GITHUB_*` files.
- Every HTTP call goes through `Invoke-Http`. Tests mock `Invoke-WebRequest` once, with the fake tenant.
- Collect first, decide second, act third. Decisions are pure functions of collected data, so the production ring sees every environment, and tests do not need a tenant.
- Anything listed or processed is sorted with `Sort-Items` / `Sort-ByDisplayName` (natural, ordinal A to Z). Never `Sort-Object` on names: it compares with culture rules, so Windows and Linux agents would disagree.
- Status colours go through `Write-Colored` (Host.ps1) and always repeat a text tag. Colour is never the only signal.
- Diagrams: edit `docs/diagrams/*.mmd` and re-render the matching `docs/images/*.svg` (see docs/architecture.md).

## Running the tests

PowerShell 7.2+ and Pester 5.7.1:

```powershell
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck
Invoke-Pester ./tests
```

No tenant is contacted. `tests/TestHelpers.ps1` describes a fake tenant (`New-FakeEnv`, `New-FakeApp`, `Set-FakeTenant`) that answers every call the module makes. CI (`.github/workflows/ci.yml`) runs the suite on Linux and Windows, PSScriptAnalyzer, a YAML syntax check and `tests/sync_keep_settings_test.py` (`python3 tests/sync_keep_settings_test.py`) on every pull request.

## Submitting a pull request

- Fork the repository and create a branch from `main`.
- Make your change. Keep it focused and small where possible.
- Add or update a test for it. A bug fix starts with a failing test.
- Test against a non-production tenant or environment, with `whatIf = true` first.
- Update the docs and `CHANGELOG.md` (Unreleased section) if relevant.
- Open the pull request with a clear description of the change and why it helps.

## Coding style

- PowerShell: prefer approved verbs and clear parameter names.
- Guard collection counts with the `Get-Count` helper. Do not rely on `.Count` of possibly-empty or scalar values.
- Keep every configurable value overridable through the variable group, with a sensible default in the script.
- Fail loudly on real errors, but report custom-install apps as **Install in admin center** (`[MANUAL]`) rather than as failures.
- Report what an API returned. Do not assert a cause that has not been verified.
- Each Finance and Operations capability gets exactly one variable, and its default is the safe/inert value. Do not introduce a second variable, alias, or default that can produce the same effect as an existing switch.
- **Use a platform label only for the question it actually answers.** `finopsversions` returns `releaseStage` (`QualityUpdate`, `GeneralAvailability`, ...). It describes the build itself, not the build's relationship to a given environment. A quality update on a newer release train is still staged `QualityUpdate`. Before using any API field in a decision, verify what it is relative to - the build, the environment, or the tenant.

## Non-negotiable invariants

These are not style preferences. Each one has already caused a real failure in this project.

### 1. Never let a local variable collide with a parameter name

PowerShell variable names are **case-insensitive**. A local named `$finOpsOnly` is the *same variable* as a `[string]` parameter `$FinOpsOnly`. Assigning a boolean to it coerces the value to the string `"False"`, which is **truthy**, so a guard fires when it should not. This once skipped the entire application phase. In v3 all settings live in one `$settings` object. Keep it that way, and never reuse a parameter name for a local.

### 2. The exit code is decided in one place

Any external tool (notably `pac`) that leaves a non-zero `$LASTEXITCODE` would fail the task even when the run succeeded. Reset it after **every** external invocation, including in the `catch` block. `Complete-Run` (Host.ps1) is the only place that decides the result. `Invoke-D365TenantAppUpdate` returns exactly one integer and the entry script exits with it. A test checks that nothing else leaks onto the pipeline.

### 3. Read the HTTP error body from the right place

PowerShell puts the HTTP response body in `$_.ErrorDetails.Message`, **not** `$_.Exception.Message`. Reading only the latter once misclassified nine apps that need the admin center install wizard (now reported as **Install in admin center**, `[MANUAL]`) as failures. Use the `Get-ErrorText` helper.

### 4. Do not short-circuit a probe across environments

An earlier build stopped probing after the first `RouteNotFound` and assumed every other environment would behave the same. A 404 over REST costs about 25 ms, so probing every environment is effectively free. Probe them all.

### 5. Destructive behaviour must be opt-in, and only one variable may ever enable it

`finOpsApplyVersion` is the single variable that governs Finance and Operations version apply. Do not add a second variable, alias, or combined switch that can also turn it on.

### 6. Never use the Anchor Solution version for an F&O decision

Microsoft has confirmed that the F&O Provisioning App Anchor Solution version in Dataverse is only updated when an update runs from Lifecycle Services, not from PPAC or the Power Platform API. This pipeline updates through the API, so after its first apply the value is permanently stale. v2.4.2 read the release train from it and misread every environment it had already updated.

The Anchor Solution may be used to **detect** that F&O is installed (presence). Its **version** must not be used for anything: not the train, not a guard, not a label.

The current release train comes from the **live application build** (`applicationVersion` from `finopsproperties`) through the build-prefix map, which is built on every run from Microsoft's [PQU release schedule](https://learn.microsoft.com/dynamics365/fin-ops-core/dev-itpro/get-started/quality-updates-schedule). Do not add a step that requires users to maintain anything by hand. The built-in map is only a fallback for when the download fails. If you extend it, take the prefix from that page's "Application Version" column and cite it in the commit.

### 7. An update scope must fail safe

`QualityUpdate` once moved ten environments from 10.0.48 to 10.0.49, because the scope relied on `releaseStage` alone. Any rule that limits how far an apply may go must:

- check every condition the scope promises (here: stage **and** release train),
- take its inputs from **live** state the platform reports on every run, not from a record that only some update paths maintain,
- bound how far it can move (`VersionUpdate` moves one train at a time, released stages only),
- **skip** the apply when a required input is missing or unparseable, rather than fall back to a wider selection, and
- never rely on the platform to refuse a bad request (for example a downgrade) unless that behaviour has been verified live.

Missing a patch is acceptable. Moving an environment further than the operator asked for is not.

### Other traps worth knowing

- **Backtick escape:** in `"$uri$sep`api-version=..."`, `` `a `` is the BELL character. Use `"${sep}api-version="`.
- **`.Count` under StrictMode** throws on `$null`, scalars, and empty generic lists. Avoid `System.Collections.Generic.List` combined with `-f` formatting over pipelines.
- **`$env` is reserved.** Never use it as a loop variable.
- **Detection must check state.** The package list is fetched with `appInstallState=All`, so it includes apps merely *offered*. Matching without checking `state -eq 'Installed'` once flagged every environment as F&O.
- **Undefined `$(var)` passed as a script argument crashes PowerShell.** Pass optional values through the pipeline `env:` block.
- **Linux environment variables are case-sensitive.** GitHub runners are Linux: the workflow maps every variable to the exact setting name under `env:`.
- **Azure Pipelines does not support YAML anchors.** Share blocks through template parameters, as `run-updater.yml` does.
- **A collapsible `##[group]` label should be the finding, not a placeholder.** Azure DevOps shows the label even when the group is collapsed.
- **Member enumeration on arrays.** `$array.prop` returns one value per element, so on an array of objects without `prop` it is an array of `$null`s, which is truthy for 2+ elements. Check `-isnot [array]` and `PSObject.Properties[...]` before unwrapping a response. This once made every multi-version `finopsversions` response read as "no versions listed".
- **Do not use `$top` on a Dataverse query you page with `@odata.nextLink`.** `$top` suppresses the next link.

## Validation checklist before shipping a change

- `Invoke-Pester ./tests` passes (CI also runs it on Windows).
- PSScriptAnalyzer reports no errors (CI).
- The YAML parses (CI).
- `$LASTEXITCODE` is reset after every external call.
- Any change to `finOpsUpdateScope` is covered by `tests/Scenario/FinOpsScenarios.Tests.ps1`, which includes: a version on a **newer** release train staged `QualityUpdate`, a version **two** trains ahead, a non-released stage, a version on a **lower** train than the live build, an **unknown** build prefix, and a `finopsversions` response with **two or more** entries, both as a bare array and wrapped in `value`.

**Always run with `whatIf = true` first.**

## Releasing (maintainer)

1. Bump `ModuleVersion` in `src/D365TenantAppUpdater/D365TenantAppUpdater.psd1`, add the version's section to `CHANGELOG.md` (start it with a short Highlights part), update the README badge, merge to `main`. The whole section for the version becomes the GitHub release notes.
2. Tag and push: `git tag v3.0.0 && git push origin v3.0.0`.
3. `.github/workflows/release.yml` checks the tag matches the manifest, runs the tests, and publishes the GitHub release with the version's `CHANGELOG.md` section as notes and a zip. If you made the release in the GitHub web UI first, the workflow keeps its title and notes and only attaches the zip. A release for a tag lower than the highest existing tag (for example a v2 patch after v3) is not marked Latest, so synced Azure DevOps copies do not move back.
4. Azure DevOps mirrors using `sync-from-github.yml` pick up the new release on their next sync.

## Security

If you find a security issue, please do not open a public issue. Contact the maintainer through LinkedIn instead: [https://www.linkedin.com/in/lazejanev/](https://www.linkedin.com/in/lazejanev/)
