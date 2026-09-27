# Release Notes

## v2.4.1 - 2026-09-27

Wording only. No logic changed.

Finance and Operations scope messages now use Microsoft's own public terminology instead of internal enum values:

- `QualityUpdate` displays as **PQU** (matching Microsoft's "proactive quality update" terminology).
- `VersionUpdate` displays as **version update**.
- Every `[stage]` bracket in a headline is now `[Status: stage]`.
- The diagnostic line listing available versions is now labeled "New version available" rather than the bare "Available".

Example, before and after (environment name is an illustrative placeholder):

```
Before: Dev04: ... - no QualityUpdate version offered. Available: 10.0.49.2 [GeneralAvailability]
After:  Dev04: ... - no PQU version available. New version available: 10.0.49.2 [Status: GeneralAvailability]
```

No release-stage matching, scope filtering, or apply decision changed. If you compared two runs before and after this release and the wording differences confused you at first, that confusion is expected and resolved by this note alone - the underlying `finopsversions` route itself is separately known to be intermittent (see v2.4.0 below and `docs/setup.md`), and can produce a genuinely different result between two runs regardless of this script.

## v2.4.0 - 2026-09-27

Removes the F&O Provisioning App Anchor Solution from every decision this script makes, and replaces it with Microsoft's own version classification.

### Why this release exists

The previous approach (introduced in v2.3.3) used the Anchor Solution's Dataverse-registered version as the reference point for deciding whether an available F&O version was a same-train patch or a new release train. This was confirmed live to be unreliable in a way that was structural, not occasional: **multiple environments in a single run shared the identical live application build**, yet their Anchor Solution readings split into two different values. The reason: Microsoft's own automated Unified environment service update rollout does not update that Dataverse record at all - only a Dataverse-level solution operation (an environment copy from an already-updated source, or an explicit solution import) does. An environment updated the normal way could carry a stale Anchor Solution version indefinitely while being completely current in reality.

The fix removes the Anchor Solution from the decision path entirely. It turns out the platform already answers the question directly: `finopsversions` returns a `releaseStage` field on every entry (for example `{"version":"10.0.48.7","releaseStage":"QualityUpdate"}`). There was never a need to derive a classification from a proxy value when the platform's own answer was in the response the whole time.

### Highlights

- **`finOpsUpdateScope` now matches Microsoft's own `releaseStage`**, not a derived comparison. `QualityUpdate` selects only versions staged `QualityUpdate`; `VersionUpdate` selects only versions staged anything else; `Any` ignores stage and picks the numerically highest.
- **Anchor Solution demoted to a labeled, non-decisive diagnostic value.** Still shown under `dumpDiagnostics`, never in a headline, never used to accept/reject/classify anything.
- **Finance and Operations output rewritten to be dramatically shorter.** A long explanatory sentence used to repeat in full on every environment line; it now prints once, in a legend at the top of the section. Each environment gets one compact headline.

### Upgrade notes

- No variable changes. `finOpsUpdateScope` still accepts `QualityUpdate` / `VersionUpdate` / `Any`; only what it is matched against changed (for the better).
- If your log output looked different across two recent runs and you suspected a regression: check whether both runs actually returned data from `finopsversions` (HTTP 200) or whether one hit the known-intermittent `RouteNotFound` condition (see `docs/setup.md`). A byte-for-byte diff between two script versions plus a diff between two run logs is the reliable way to tell "the script changed" apart from "the platform's response changed between runs" - the latter has been confirmed to happen with zero code or config changes in between.

## v2.3.x series - 2026-09-19 through 2026-09-26

Incremental hardening of the Finance and Operations phase, culminating in v2.4.0 above:

- **v2.3.0**: `finOpsApplyVersion` introduced as the single Finance and Operations on/off switch. Dead settings (`pollIntervalSec`, `pollTimeoutMin`) removed. Transport failures reported honestly instead of as `HTTP -1`. PowerShell 7 required for this phase.
- **v2.3.1**: Removed a client-side "already at or above" pre-check that compared two incompatible version schemes; the apply call's own response became the sole authority.
- **v2.3.2**: Admin Mode detection added for Phase 1 - an environment left in Administration Mode is now detected on the first failure and every remaining app for it is skipped, rather than repeating the identical failure per app.
- **v2.3.3**: `finOpsUpdateScope` introduced, initially classified using the Anchor Solution as a reference (later replaced in v2.4.0).
- **v2.3.4**: Fixed a regression where the v2.3.1 fix had been accidentally undone during a rebuild.
- **v2.3.5**: The F&O Provisioning App Anchor Solution excluded from Phase 1's generic install loop, resolving a contradiction where the same version jump was reported as both a failure and a success.
- **v2.3.6**: Output reorganised to one headline per environment; inventory table made unconditional; `dumpSolutionCatalog` split out from `dumpDiagnostics`.
- **v2.3.7 / v2.3.8**: Iterated on whether Finance and Operations detail should use collapsible groups. Landed on: keep the groups, but set the group's label to the actual headline so the outcome is visible even collapsed.
- **v2.3.9**: Identified and explained the Anchor Solution lag with a warning label, one release before removing it from the decision path entirely in v2.4.0.

## v2.2.0 - 2026-09-18

Adds Finance and Operations environment inventory, and implements F&O application version updates against the documented Power Platform routes, gated behind a live route check.

## v2.0.0 - 2026-08-18

Reduced required configuration to three variables (`ClientId`, `ClientSecret`, `TenantId`), with every other setting optional and defaulted in the script.

## v1.x series - 2026-08-16 through 2026-08-18

Initial public release and early hardening: environment discovery, version comparison with strict never-downgrade logic, `AppExclude` / `EnvironmentExclude` deny-lists, Custom Install Experience detection, and the optional PAC CLI fallback.
