# Security Policy

## Supported versions

Only the latest release on `main` is supported with security fixes.

## Reporting a vulnerability

Please **do not** put exploit details in a public issue.

Preferred channel: [GitHub private vulnerability reporting](../../security/advisories/new) (Security → Report a vulnerability). If that page is unavailable — the feature only exists on public repositories and must be enabled by the maintainers — open an issue with the `security` label that describes the *area* affected (no exploit details) and how to reach you privately. You will get an acknowledgment within 7 days either way.

## Scope notes

- This tooling drives an approval-gated adoption pipeline. Anything that could cause an **adoption to complete without its human approval gate** (state-machine bypass, ledger tampering, forged council verdicts) is in scope and treated as `severity:critical`.
- The proposal ledger data plane is private infrastructure and out of scope for this repository, but reports about this tooling *writing* somewhere it should not are in scope.
