# Trial isolation

Every trial runs outside the live working copy and uses controls proportional to
its ledger `risk_tier`. The executor records the chosen runtime, isolation method,
network use, and spot-check results in the artifact bundle.

## Isolation routing

The normative tier table lives in [adoption-wiring.md](adoption-wiring.md).
This document supplies the operational isolation detail that implements it.

Identity-critical work is routed through council and Sho regardless of the tier a
mechanical rollback would otherwise receive.

## T0 and T1 code isolation

Use a dedicated git worktree when the trial needs repository history or a scratch
directory when it does not. Never experiment in the live checkout. Before making
workspace-level changes, verify that no other agent or session is using the trial
checkout and record the result in `run.log`.

The rollback statement must be quantitative whenever possible, for example:
`rollback = git worktree remove + git branch -D, <10 min, no data loss`.

## T1 secrets-clean environment

A trial of a new tool, SDK, or MCP server receives only an explicit environment
allowlist. It must not inherit credentials or an SSH agent, must not mount
`~/.ssh`, and may use only disposable trial-specific keys. Document every network
destination and purpose in `permissions.md`.

Create a temporary home outside the live home and launch the trial like this:

```bash
trial_home=$(mktemp -d "${TMPDIR:-/tmp}/sgl-trial-home.XXXXXX")
env -i \
  HOME="$trial_home" \
  PATH='/usr/bin:/bin:/usr/sbin:/sbin' \
  TMPDIR="${TMPDIR:-/tmp}" \
  LANG="${LANG:-C}" \
  TERM="${TERM:-dumb}" \
  /bin/bash --noprofile --norc
```

Inside that shell, run this secrets-clean spot check before the trial:

```bash
if test -r "$HOME/.ssh/id_ed25519"; then
  echo "FAIL: private SSH key is readable" >&2
  exit 1
else
  echo "PASS: ~/.ssh/id_ed25519 is not readable"
fi

test -z "${SSH_AUTH_SOCK:-}" || exit 1
if env | grep -E '(^|_)(TOKEN|SECRET|PASSWORD|CREDENTIAL|API_KEY)='; then
  echo "FAIL: credential-like environment variable inherited" >&2
  exit 1
fi
```

The direct `test -r ~/.ssh/id_ed25519` check must take the failure branch and print
`PASS`; the SSH-agent check must succeed; and the scan must print no
credential-bearing variables. Record pass/fail without printing secret values.
Remove the temporary home after preserving only the required, reviewed artifact
bundle.

## T2 gate

Do not begin a trial involving production data or paid resources unless both
conditions are met:

1. The collection-controls prerequisite (tracked on the operator's private tracker) is closed, providing the required collection controls.
2. Sho has explicitly pre-approved the concrete trial plan.

The collection pipeline behind condition 1 is public:
[caty-ai/x-collector](https://github.com/caty-ai/x-collector). Trials that
need collected production data go through that pipeline and inherit its
collection controls instead of collecting on their own; the prerequisite is
that this control work is finished, not merely that the pipeline exists.

Approval is plan-specific. Record its reference and the spending/data boundaries
in `permissions.md`; an approval for a prior trial does not carry forward.
