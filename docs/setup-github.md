# Setup: GitHub Actions

New in v3.0.0. This guide takes you from nothing to a working GitHub Actions workflow. It runs the same module, with the same settings and the same safety rules, as the Azure DevOps pipelines. Using Azure DevOps instead? See [setup-azure-devops.md](setup-azure-devops.md).

The workflow is `.github/workflows/tenant-app-updater.yml`. It has three jobs:

```
Plan  ->  Apply non-production  ->  Apply production
          (only if the plan has      (only if the plan has production
           non-production actions)    actions; runs in the GitHub
                                      environment d365-production)
```

**Plan** reads the whole tenant and writes the plan and the job summary. It changes nothing. The two **Apply** jobs apply their part of the plan, re-checking each action against the live tenant first.

Sign-in uses **OpenID Connect**: GitHub gives each job a short-lived token that Microsoft Entra ID trusts, so **no client secret is stored**. A client secret is supported as a backup.

## 1. Get your own copy of the repository

- **Fork** the repository, or create a new repository from it (**Use this template**, or push a clone). A private repository is fine.
- In a fork, workflows are disabled until you enable them: **Actions** tab > **I understand my workflows, go ahead and enable them**.

## 2. Create the service principal

Same as for Azure DevOps:

- Entra admin center > **Entra ID > App registrations > New registration**, for example `d365-tenant-app-updater`. No redirect URI.
- Note the **Application (client) ID** and **Directory (tenant) ID**.
- Grant the permissions in [permissions.md](permissions.md): register it as a Power Platform management application, and add it as an application user with a security role in each environment's Dataverse. This is the step most first runs fail on.

## 3. Trust GitHub (federated credentials)

Add two federated credentials to the app registration, one per kind of job. **Certificates & secrets > Federated credentials > Add credential > GitHub Actions deploying Azure resources**:

| Credential | Organization / Repository | Entity type | Value | Used by |
|---|---|---|---|---|
| `github-main` | your owner / your repository | **Branch** | `main` | Plan and Apply non-production (manual and scheduled runs on `main`) |
| `github-production` | your owner / your repository | **Environment** | `d365-production` | Apply production |

The resulting subjects are `repo:<owner>/<repo>:ref:refs/heads/main` and `repo:<owner>/<repo>:environment:d365-production`. The audience stays `api://AzureADTokenExchange`.

If you run the workflow from another branch, add a credential for that branch too. If your organization customizes the OIDC subject claim, use the subject GitHub actually sends (the sign-in error shows it).

## 4. Repository variables (and an optional secret)

**Settings > Secrets and variables > Actions**.

Variables tab, required:

| Name | Value |
|---|---|
| `D365_CLIENT_ID` | Application (client) ID |
| `D365_TENANT_ID` | Directory (tenant) ID |

Optional: any setting from [parameters.md](parameters.md#github-variable-names), for example `ENVIRONMENT_EXCLUDE`, `FINOPS_APPLY_VERSION`, `PRODUCTION_ENVIRONMENTS`. Absent variables use the built-in defaults.

Secrets tab, optional: `D365_CLIENT_SECRET`. With `AUTH_MODE` unset (`Auto`), the workflow signs in with OpenID Connect and only uses the secret if that sign-in is refused (the log then says so, with the reason). Set `AUTH_MODE = Federated` once OIDC works to make sure the secret is never used, and delete the secret.

## 5. The production environment (optional approval)

**Settings > Environments > New environment** > `d365-production`. GitHub also creates it automatically on the first run that has production actions.

By default it has no protection rules, so production follows automatically once non-production proves a version (the production ring, on by default). To have a person approve production, add **Required reviewers** to the environment.

> Required reviewers on environments are free for public repositories. For private repositories they need GitHub Team or Enterprise (or Pro for personal accounts). Without them, the production ring still protects production; there is just no manual gate.

## 6. First run (plan only)

- **Actions** tab > **D365 tenant app updater** > **Run workflow**.
- Set **Plan only** to `true`, run.
- Open the run. The **Plan** job's summary shows the environments in scope (A to Z, each with its ring), the planned actions, anything **Held for production**, the Finance and Operations table, and anything that needs attention. The `plan` artifact holds `plan.json`, `summary.md` and `report.json`.
- The Plan job log shows `Sign-in : Federated (GitHub OIDC)`.
- When the plan looks right, run again with **Plan only** = `useVariableOrDefault` (or `false`).

## 7. Schedule it (optional)

Uncomment the `schedule:` block in `.github/workflows/tenant-app-updater.yml` and commit to `main`. Times are UTC.

- Scheduled runs use repository variables only (there are no inputs), so set `FINOPS_APPLY_VERSION` and friends as variables.
- **GitHub disables scheduled workflows in a public repository after 60 days without activity** in the repository. It emails you first; re-enable the workflow in the Actions tab. Private repositories are not affected.
- With the production ring on, a nightly schedule updates non-production every night and production the night after non-production has run a version.

## 8. What differs from Azure DevOps

| | Azure DevOps | GitHub |
|---|---|---|
| Settings | Variable group `D365-TenantAppUpdater`, setting names (`environmentExclude`) | Repository variables, UPPER_SNAKE names (`ENVIRONMENT_EXCLUDE`) |
| Sign-in | Client secret, or federated service connection (preview) | OpenID Connect, secret as backup |
| Production gate | Environment `d365-production`, Approvals check | Environment `d365-production`, Required reviewers |
| Run summary | Extensions tab | Job summary |
| A run with issues | Orange (SucceededWithIssues) | Green with warning annotations (GitHub has no orange state); set `FAIL_ON_ISSUES = true` to fail it |
| PAC CLI fallback (`usePacFallback`) | Supported with the client secret | Not installed on the runner; apps that need the admin center wizard are reported instead |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | The subject GitHub sent is not in the app's federated credentials (other branch, or the environment credential missing) | Add the credential from section 3 that matches the job that failed |
| `Could not get a GitHub OIDC token` | The workflow lost `permissions: id-token: write` | Restore the `permissions:` block at the top of the workflow |
| `No way to sign in` | Neither OIDC nor `D365_CLIENT_SECRET` is available | Check `D365_CLIENT_ID`, `D365_TENANT_ID` and the `permissions:` block |
| `Forbidden` listing environments | The app is not a Power Platform management application | [permissions.md](permissions.md), layer 2 |
| An environment shows "solutions unavailable" | No application user in that environment | [permissions.md](permissions.md), layer 3 |
| Apply production never runs | No production actions (nothing proven yet, or nothing to update), or the run was Plan only | Check **Held for production** in the Plan summary |
| The schedule stopped | 60 days without repository activity (public repository) | Re-enable the workflow in the Actions tab |

More symptoms, shared with Azure DevOps, are in [setup-azure-devops.md](setup-azure-devops.md#troubleshooting).
