# Contributing

Thanks for your interest in improving this project. Issues and pull requests are welcome.

## Ground rules

- Be respectful and constructive. This is a community project maintained in spare time.
- Never commit secrets. No tenant IDs, environment IDs, application or client IDs, secrets, org URLs, or customer names. Use placeholders like `$(ClientId)` and `$(TenantId)` and document them in `docs/parameters.md`.
- Keep the pipeline generic. Nothing in this repo should be tied to a specific customer, tenant, or environment.

## Reporting issues

When you open an issue, include:

- What you expected to happen and what actually happened.
- The relevant part of the pipeline log, with all IDs, secrets, and customer names redacted.
- Your agent type (Microsoft-hosted or self-hosted) and PowerShell version.
- The parameter values you used, redacted where needed.

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your change. Keep it focused and small where possible.
3. Test against a non-production tenant or environment.
4. Update the docs and `CHANGELOG.md` under the Unreleased section.
5. Open the pull request with a clear description of the change and why it helps.

## Coding style

- PowerShell: use approved verbs, `Set-StrictMode -Version Latest`, and clear parameter names.
- Prefer functions with a single responsibility over long inline blocks.
- Fail loudly. Surface API errors with enough context to diagnose them.
- Do not swallow exceptions unless there is a documented reason, such as an optional retry.

## Security

If you find a security issue, please do not open a public issue. Contact the maintainer through LinkedIn instead: https://www.linkedin.com/in/lazejanev/
