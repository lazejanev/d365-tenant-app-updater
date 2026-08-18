# Contributing

Thanks for your interest in improving this project. Issues and pull requests are welcome.

## Ground rules

- Be respectful and constructive. This is a community project maintained in spare time.
- Never commit secrets. No tenant IDs, environment IDs, application or client IDs, secrets, org URLs, or customer names. The only required inputs are provided at run time through the variable group.
- Keep it generic. Nothing in this repo should be tied to a specific customer, tenant, or environment.

## Reporting issues

When you open an issue, include:

- What you expected to happen and what actually happened.
- The relevant part of the pipeline log, with all IDs, secrets, and customer names redacted.
- Your agent type (Microsoft-hosted or self-hosted) and PowerShell version.
- Which variables you set in the group (names only, values redacted).

## Submitting a pull request

1. Fork the repository and create a branch from `main`.
2. Make your change. Keep it focused and small where possible.
3. Test against a non-production tenant or environment.
4. Update the docs, `CHANGELOG.md` (Unreleased section), and `RELEASE_NOTES.md` if relevant.
5. Open the pull request with a clear description of the change and why it helps.

## Coding style

- PowerShell: prefer approved verbs and clear parameter names.
- Guard collection counts with the `Get-Count` helper; do not rely on `.Count` of possibly-empty or scalar values.
- Keep every configurable value overridable through the variable group, with a sensible default in the script.
- Fail loudly on real errors, but classify custom-install apps as `manual-required` rather than failures.

## Security

If you find a security issue, please do not open a public issue. Contact the maintainer through LinkedIn instead: https://www.linkedin.com/in/lazejanev/
