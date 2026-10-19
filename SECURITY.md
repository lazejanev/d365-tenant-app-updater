# Security policy

## Reporting a problem

Please do not open a public issue for a security problem.

Report it privately through GitHub: **Security** tab → **Report a vulnerability** ([direct link](https://github.com/lazejanev/d365-tenant-app-updater/security/advisories/new)). You get a reply as soon as possible, usually within a few days.

Examples of what to report:
- a way for the pipeline to expose a client secret or token in logs or artifacts
- a way for a run to change an environment it was told not to touch (excluded, production without proof, F&O without `finOpsApplyVersion`)
- a dependency or workflow setting that lets someone else run code in your pipeline

## Supported versions

Fixes go into the latest release. The sync pipeline (`sync-from-github.yml`) follows the latest release by default, so synced copies get them on the next sync.

## Keeping your setup safe

- Store the client secret only as a secret variable (Azure DevOps) or a repository or environment secret (GitHub). Better still, use federated sign-in and no secret at all.
- Give the app registration only the roles described in [docs/permissions.md](docs/permissions.md).
- Never paste secrets, tokens or tenant IDs into issues, logs you share, or screenshots.
