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

- Fork the repository and create a branch from `main`.
- Make your change. Keep it focused and small where possible.
- Test against a non-production tenant or environment.
- Update the docs, `CHANGELOG.md` (Unreleased section), and `RELEASE_NOTES.md` if relevant.
- Open the pull request with a clear description of the change and why it helps.

## Coding style

- PowerShell: prefer approved verbs and clear parameter names.
- Guard collection counts with the `Get-Count` helper; do not rely on `.Count` of possibly-empty or scalar values.
- Keep every configurable value overridable through the variable group, with a sensible default in the script.
- Fail loudly on real errors, but classify custom-install apps as manual-required rather than failures.
- Report what an API returned. Do not assert a cause that has not been verified. `finopsversions returned HTTP 404 RouteNotFound` is a fact; an explanation of *why* the route is missing is a guess, and guesses have been wrong here before.
- Each Finance and Operations capability gets exactly one variable, and its default is the safe/inert value. Do not introduce a second variable, alias, or default that can produce the same effect as an existing switch; that is precisely how a route becoming available on the platform side could silently change behaviour for users who never opted in.

## Non-negotiable invariants

These are not style preferences. Each one has already caused a real failure in this project.

### 1. Never let a local variable collide with a parameter name

PowerShell variable names are **case-insensitive**. A local named `$finOpsOnly` is the *same variable* as a `[string]` parameter `$FinOpsOnly`. Assigning a boolean to it coerces the value to the string `"False"`, which is **truthy**, so a guard fires when it should not. This once skipped the entire application phase.

**Rule:** every local is prefixed `opt*` or `cfg*`. Verify before you push:

```python
params  = set(x.lower() for x in re.findall(r'\[Parameter\([^)]*\)\]\s*\[string\]\s*\$(\w+)', s))
assigns = set(x.lower() for x in re.findall(r'^\s*\$(\w+)\s*=', s, re.M))
assert not (params & assigns)   # MUST be empty
```

### 2. Always reset `$LASTEXITCODE` after an external call, and `exit 0` explicitly

Any external tool (notably `pac`) that leaves a non-zero `$LASTEXITCODE` will fail the Azure DevOps task even when the run itself succeeded. Reset it after **every** external invocation, including in the `catch` block, and end the script with an explicit `exit 0`.

### 3. Read the HTTP error body from the right place

PowerShell puts the HTTP response body in `$_.ErrorDetails.Message`, **not** `$_.Exception.Message`. The latter only contains "Response status code does not indicate success". Reading only the latter once misclassified nine "manual install required" apps as failures. Use the `Get-ErrorText` helper.

### 4. Do not short-circuit a probe across environments

An earlier build stopped probing after the first `RouteNotFound` and assumed every other environment would behave the same, which hid possible per-deployment-type differences. A 404 over REST costs about 25 ms, so probing every environment is effectively free. Probe them all.

### 5. Destructive behaviour must be opt-in, and only one variable may ever enable it

`finOpsApplyVersion` is the single variable that governs Finance and Operations version apply. It exists precisely because the apply path is gated behind a live route check and would otherwise activate on its own the moment the route became available. Do not add a second variable, alias, or combined switch that can also flip this on: a variable that used to have that effect (`updateFinOpsVersion`) is now explicitly retired and ignored rather than repurposed, for exactly this reason. Any future capability with the same shape (implemented, dormant, waiting on a platform change) gets its own explicit switch, defaulting to off, reachable through exactly one variable.

### Other traps worth knowing

- **Backtick escape:** in `"$uri$sep`api-version=..."`, `` `a `` is the BELL character. Use `"${sep}api-version="`.
- **`.Count` under StrictMode** throws on `$null`, scalars, and empty generic lists. Avoid `System.Collections.Generic.List` combined with `-f` formatting over pipelines ("Argument types do not match").
- **`$env` is reserved.** Never use it as a loop variable.
- **Detection must check state.** The package list is fetched with `appInstallState=All`, so it includes apps merely *offered*. Matching without checking `state -eq 'Installed'` once flagged every environment as F&O.
- **Undefined `$(var)` passed as a script argument crashes PowerShell.** Pass optional values through the pipeline `env:` block so an undefined variable arrives as a harmless literal the script ignores.
- **`-SkipHttpErrorCheck` is PowerShell 7 only.** Guard any new use of it, as the F&O phase does.

## Validation checklist before shipping a script change

```python
# 1. Balanced (strip single-quoted strings and {0} placeholders first)
s2 = re.sub(r"'[^'\n]*'", "''", s); s2 = re.sub(r'\{\d+[^}]*\}', '', s2)
assert s2.count('{') == s2.count('}')
assert s2.count('(') == s2.count(')')

# 2. NO parameter/local collisions (case-insensitive)
assert not (params & assigns)

# 3. Ends with exit 0
assert s.rstrip().endswith('exit 0')
```

Also confirm: the YAML parses, `$LASTEXITCODE` is reset after every external call, and no `Generic.List` is used with `-f` over a pipeline.

**Always suggest running with `whatIf = true` first.**

## Security

If you find a security issue, please do not open a public issue. Contact the maintainer through LinkedIn instead: [https://www.linkedin.com/in/lazejanev/](https://www.linkedin.com/in/lazejanev/)
