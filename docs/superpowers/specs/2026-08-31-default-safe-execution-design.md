# Default-safe execution - design

**Date:** 2026-08-31
**Status:** approved, ready to implement

## Why

`awesome-agentic-devops` [declined heliograph][pr] on 31 Aug. Adoption was one reason and there is
nothing to argue about there. The other reasons were about the execution model, and they were right:

- the unattended loop allows state-changing steps by default;
- a step is classified as read-only or not **by its filename**, so `cleanup-disk` is treated as a
  diagnostic whatever it actually does;
- nothing constrains which account the loop runs as, so blast radius is undefined;
- `cap_redact` covers six shapes and misses the self-identifying token formats that appear in real
  logs (`AKIA…`, `ghp_…`, JWTs, an `Authorization:` header with any other scheme).

Measured against that catalog's [operator safety checklist][checklist], heliograph fails §1 (start
read-only), §4 (approval gate) and §5 (blast radius), and passes §6 (evidence) comfortably.

[pr]: https://github.com/DevOpsAIguru123/awesome-agentic-devops/pull/104
[checklist]: https://github.com/DevOpsAIguru123/awesome-agentic-devops/blob/main/docs/operator-safety-checklist.md

## The history that matters

heliograph *was* default-safe. PR #2 (`d13aa42`) flipped `ALLOW_ACTIONS` to 1 for a real reason: the
flag was typed once at agent start, often days before the request it gated, and forgetting it
surfaced as a silent `refused` long after the push - wasting exactly the round trip this tooling
exists to save.

That reason has since expired. The refusal now publishes `state: refused` with a reason to
`agent/status` within one poll interval, so the requester learns in seconds rather than never. The
default can go back to safe without re-creating the cost that changed it.

## Six changes

### 1. A step declares its own mode, and an undeclared step does not run

Every step file carries a header line in its first 30 lines:

```bash
# heliograph-mode: read-only     # or: action
```

`run.sh` reads it from the step's own file and gates on that instead of on the step's name. Three
outcomes:

| declared | result |
|---|---|
| `read-only` | runs |
| `action` | runs only with `CONFIRM=yes` |
| missing, or any other value | refuses, exit 3, naming the file and the line to add |

Fail closed. The old `case "$STEP" in reset\|destroy\|apply\|deploy)` list goes.

This does not stop a step author declaring `read-only` and then writing `rm -rf` - nothing in a
shell tool can. What it changes is that the classification is now an explicit statement in the file
being run, checked at the boundary, instead of an inference from a filename.

**`run.sh --mode <step>`** prints the declared mode and exits without side effects. The agent asks
`run.sh` rather than re-implementing the step table, so the mapping stays in one place.

### 2. The unattended loop is read-only by default

`ALLOW_ACTIONS` defaults to `0`. An action-mode step is refused unless the operator started the
agent with `--allow-actions`. `is_action_step` asks `run.sh --mode`; the existing `ACTION_ENV`
promotion (`APPLY=1` and friends in the request's `env:` line) stays, because an env var can turn a
read-only step into a writing one and the declaration cannot see that.

The refusal already reaches the far side through `publish_status "refused"`. That is what makes this
affordable.

### 3. The runner refuses to run as root

`cap_refuse_root` in `caplib.sh`, called by `run.sh`, `caprun.sh` and `agent.sh`. Override with
`ALLOW_ROOT=1` (or `--allow-root` on the agent) for a container that genuinely has no other user.

The shipped container and the Kubernetes manifest already run as uid 1000, and the Azure VM
cloud-init creates an unprivileged `heliograph` user. This turns that convention into something the
runner enforces rather than something a manifest is trusted to have got right.

### 4. The credential boundary is written down

heliograph holds no credentials, so §1's table of least-privilege boundaries has no row that fits
it. The honest answer is that **the OS account the loop runs as is the boundary**, and `SECURITY.md`
should say so and give the read-only evaluation recipe: a dedicated unprivileged user, no sudo, a
private transport repo, no cloud credentials of any kind.

### 5. `cap_redact` learns the self-identifying token formats

Added, each with masked *and* left-alone assertions in `tests/test-redact.sh`:

| shape | why it is safe to match |
|---|---|
| `ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_` | GitHub's documented prefixes |
| `AKIA…`, `ASIA…` (16 uppercase alnum) | AWS access key ids are fixed-shape |
| `xox[abposr]-…` | Slack's documented prefix |
| `glpat-…` | GitLab PAT |
| `sk-…` (20+ chars) | OpenAI-style key |
| `eyJ….….…` | a JWT is three base64url segments and nothing else looks like that |
| `Authorization: <any scheme> <token>` | only `Bearer` and `Basic` were covered |
| `AccountKey=…` | Azure storage, missed by the `key=value` rule |

Over-masking loses evidence, which is the expensive mistake in a log-only loop. Every rule above is
anchored on a prefix that a credential announces about itself, so none of them can fire on prose.

### 6. Opt-in step pinning

`REQUIRE_PIN=1 ./agent.sh` refuses any step whose file hash the operator has not approved.

- `./agent.sh --pin` records the sha256 of `run.sh`, `caplib.sh`, `lib/*.sh` and `steps/*` in
  `.agent-approved` - a local, gitignored file, because trust recorded in the transport repo could
  be edited from the far side.
- A pushed step that is new or changed is refused with `reason: step not approved`, and the operator
  re-approves with one command.

**Off by default, deliberately.** Pinning makes the operator approve every new step, which turns the
unattended loop back into the manual relay the tool exists to remove. It is here for the estate that
needs "runs only what I approved" and knows what it costs.

Pinning covers the executable surface a request can reach. It does not cover `agent.sh` itself,
which self-updates on pull; `SECURITY.md` says so plainly rather than implying a boundary that is
not there.

## Testing

- `tests/test-step-mode.sh` (new): `--mode` output per shipped step, undeclared refusal, action
  without `CONFIRM`, action with it, unknown step, `--mode` writes no log and pushes nothing.
- `tests/test-agent-gate.sh` (new): default refuses an action step, `--allow-actions` permits it,
  `ACTION_ENV` promotion still fires, refusal is published to `agent/status`, pin refusal.
- `tests/test-redact.sh` (extended): masked and left-alone cases for each new shape.
- `tests/test-root-refusal.sh` (new): refuses under a faked `id -u` of 0, allows with `ALLOW_ROOT=1`.

## What this does not claim

A step is arbitrary shell and stays arbitrary shell. Anyone who can push to the transport repo can
have the operator's account run anything it could run anyway. These changes make the default
posture read-only, make the classification explicit and checkable, bound the account, and give an
estate that wants a hard allowlist a way to have one. They do not turn a shell runner into a
sandbox, and nothing in the documentation should suggest they do.
