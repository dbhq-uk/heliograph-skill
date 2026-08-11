# AGENTS.md

Guidance for AI agents (and people) working in this repository.

## What this is

The **heliograph** skill for AI coding agents: run things on a machine nobody
present can debug, and get a readable log back, with git as the transport in both
directions. It follows the [Agent Skills](https://agentskills.io) layout
(`skills/<name>/SKILL.md`) and ships as a
[Claude Code plugin](https://code.claude.com/docs/en/plugins).

It began as an Ansible-only capture wrapper in a private estate, was generalised
off Ansible, given a branch-per-task workflow, and then packaged as a skill.
Every rule in here was paid for by an investigation that went wrong first.

## Layout

```
.claude-plugin/plugin.json          # plugin manifest
skills/heliograph/SKILL.md          # the skill (agent-facing instructions)
skills/heliograph/references/       # method, runner reference, step-writing, transport, remote repos
skills/heliograph/scripts/          # bootstrap.sh - installs the toolkit into a transport repo
skills/heliograph/toolkit/          # what gets copied out: run.sh, agent.sh, caplib.sh, lib/, steps/
install.sh / install-codex.sh       # local symlink installers (Claude / Codex)
```

**`toolkit/` is a payload, not a library this repo runs.** Nothing in it is
executed from here. It is copied into a separate, private transport repo by
`bootstrap.sh`, and it runs there, on a machine you have never seen. Edit it as
if you will not be present when it fails, because you will not be.

The toolkit ships its ignore file as `toolkit/gitignore`, without the dot, so
that it governs the transport repo rather than this one. `bootstrap.sh` restores
the dot on the way out. Do not "fix" the name.

## The constraints that must not be broken

Everything else here is a preference. These are not.

**1. Every captured line carries a UTC timestamp.** After the fact, in an untimed
log, a hang and slow progress are indistinguishable, and a gap in the timestamp
column is the only way to tell which operation stalled and for how long. It is
the single most useful property of these logs. Do not strip it for tidiness, do
not batch output and stamp it at the end, and do not buffer a command's output in
a variable before printing it: every line of that block then carries the same
time, which is worse than no timestamp because it looks like one.

**2. A failed run still ships, and a failed push never loses a log.** The log is
committed and pushed whether the step passed or failed, and the real exit code
survives via `PIPESTATUS`. If the push fails, `cap_push` prints the local path
rather than exiting. Each round trip through an operator is expensive; none of
them may be wasted by tooling that only reports success.

**3. The runner owns the log; a step just prints to stdout.** `run.sh` and
`caprun.sh` own the file, the timestamps and the push. `agent.sh` decides only
*when* a runner runs. A step script knows nothing about any of it, which is what
lets you run `./steps/foo.sh` straight to a terminal while writing it. There is
one implementation of the capture pattern, in `caplib.sh`. Do not fork it.

**4. Read-only until earned, and gated twice.** A step that changes state is
listed in `run.sh`'s `CONFIRM=yes` gate, so a stale `DEFAULT_STEP` can never do
damage on its own, and `agent.sh` refuses it unless started with
`--allow-actions`. Both gates, deliberately: an unattended loop that can apply
infrastructure because a file changed is a different proposition from one that
only reads. Never make a state-changing step the default.

**5. The transport repo is private, and separate.** Captured logs are committed
to it. `cap_redact` masks the obvious shapes and is a safety net, not a
guarantee, so anything a command prints is in that history permanently. Never
weaken `bootstrap.sh`'s insistence on a fresh target, and never suggest
bootstrapping into a repo that holds anything else.

## Conventions

- Any path a `SKILL.md` names must use `${CLAUDE_SKILL_DIR}` (the skill's own
  directory), which Claude Code substitutes for personal, project and plugin
  installs alike. `install.sh` therefore symlinks the whole skill directory into
  `~/.claude/skills/` with no rewrite; `install-codex.sh` rewrites the variable,
  because Codex does not substitute it. **Never hardcode a
  `~/.claude/skills/heliograph` path.**
- Toolkit scripts use `set -uo pipefail`, never `set -e`. A diagnostic wants
  every probe's result, not the first failure. `probe` records a failure and
  carries on. This is the opposite of the usual house rule, and it is deliberate.
- Steps never prompt. No interactive sudo, no host-key questions, no `read`. A
  prompt through the capture pipeline is invisible and the run simply hangs.
- Bash 4+, git and GNU coreutils. No packages, no interpreter beyond bash, no
  credentials of the skill's own.
- No host names, environments, findings or logs on `main`, in this repo or in a
  transport repo. `main` is the template.
- House style: British English, plain hyphens, no em dashes, no trailing full
  stops on headings.

## Validating a change

```bash
bash -n install.sh install-codex.sh
find skills -name '*.sh' -exec bash -n {} +
claude plugin validate .
shellcheck skills/heliograph/toolkit/*.sh skills/heliograph/toolkit/lib/*.sh   # if installed
```

CI runs the first three plus the frontmatter and install checks. Be honest about
what none of it covers: **nothing here exercises a capture against a real remote
machine.** The behaviour that matters is what a log looks like after a round trip
through someone else's terminal, and no test asserts that.

After changing anything under `toolkit/`, verify by hand from a bootstrapped
copy:

- `PUSH=0 ./run.sh env` produces a log where **every line** carries a UTC stamp
  and the header names the branch and commit.
- A step that exits non-zero still writes the footer, still reports the real exit
  code, and still gets committed.
- `./run.sh <a step that does not exist>` exits 2 having written nothing.

Skipping those because CI is green is how the constraints get broken.
