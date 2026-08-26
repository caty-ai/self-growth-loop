# Contributing

Thanks for your interest in self-growth-loop.

## Prerequisites

To run this repository's scripts and tests, you need:

- **bash 3.2+** — macOS system bash is the supported floor.
- **ruby** — standard library only; macOS system ruby 2.6+ and distro ruby 3.x are both exercised by CI. Every entry script checks for it first and exits 127 when it is unavailable.
- **perl + `shasum` + `expect` + `python3`** — test-only dependencies: `perl` and `shasum` are expected on minimal distros, `expect` drives PTY confirmation suites, and `python3` runs the publication-gate checker.
- **a UTF-8 locale** — the scheduled wrappers probe `en_US.UTF-8` first and `C.UTF-8` second; Linux hosts need at least one of them available.
- **make** — the family-standard entry point for tests and lint.
- **git** — for the issue-and-branch workflow below.

## Ground rules

- **Issue-first.** Every change starts as a GitHub issue stating *why*, a testable *done when*, and a prediction of the files it will touch. 1 issue = 1 branch = 1 pull request.
- **No self-merge.** Every pull request is reviewed before merge.
- **Tests are the contract.** Run the full suite before opening a PR:

  ```sh
  make test
  ```

  The integration test additionally needs a local checkout of the engine
  ([caty-ai/caty-agent-harness](https://github.com/caty-ai/caty-agent-harness)) — point
  `SGL_ENGINE_SOURCE` at it if it is not at the default location.
- **Never commit ledger data.** This repository holds schema, templates, and tooling only. Proposal records, council verdicts, and queue reports live in a private data plane and must not appear here — not even as test fixtures with real content.

## Workflow

1. Open (or pick) an issue and state your intent on it.
2. Branch from `main` (`issue-<n>-<slug>`).
3. Make the change; add or update tests next to the behavior you touched.
4. Run `make test` and include the result in the PR description.
5. Open a PR that lists the files touched and how each "done when" item was verified.

## Labels

Use `component:*` to say where, `severity:*` to say how bad, and the default type labels (`bug`, `enhancement`, `documentation`, `question`) to say what kind. Do not add new label axes without an issue discussing it first.

## Process reference

The development protocol this repo follows (issue lifecycle, review seats, merge discipline) is documented in the [family-dev-handbook](https://github.com/caty-ai/family-dev-handbook).
