# Developer setup - heliograph

Set the skill up from source with a **live symlink install**, so your edits are
active immediately in Claude Code (and Codex). End users do not need this - they
install via the [DBHQ marketplace](../README.md#install).

## Prerequisites

- `git`, `bash` 4+, GNU coreutils (and the GitHub CLI `gh` if you will push changes)
- Optional: `shellcheck`, which CI runs at `-S warning`

That is the whole list, and keeping it that short is a design constraint rather
than an accident. The toolkit has to run on control nodes where installing
anything is a change request.

## 1. Clone

```bash
git clone https://github.com/dbhq-uk/heliograph-skill.git ~/dbhq-heliograph
cd ~/dbhq-heliograph
```

## 2. Install (symlink)

```bash
./install.sh          # Claude Code: symlinks into ~/.claude/skills (edits are live)
./install-codex.sh    # Codex: installs into ~/.codex/skills
```

Any path the skill names uses `${CLAUDE_SKILL_DIR}` (the skill's own directory),
which Claude Code substitutes for personal, project and plugin installs alike.
So `install.sh` symlinks the **whole skill directory** into `~/.claude/skills/`
and every edit takes effect with no re-run. Codex does not substitute
`${CLAUDE_SKILL_DIR}`, so `install-codex.sh` rewrites it to the install path -
**re-run `./install-codex.sh` after editing `SKILL.md`** for Codex.

## 3. Work on the toolkit

`skills/heliograph/toolkit/` is never executed from this repo. It is a payload
that `bootstrap.sh` copies into a transport repo, so develop it from a
bootstrapped copy:

```bash
./skills/heliograph/scripts/bootstrap.sh /tmp/transport
cd /tmp/transport && git init -q && git add -A && git commit -qm init
PUSH=0 ./run.sh env
```

`PUSH=0` captures to `ops-logs/` without committing or pushing, which is what you
want on a throwaway. Copy anything you change back into
`skills/heliograph/toolkit/` before committing, and re-run the bootstrap into a
clean directory to confirm what you have is what ships.

A step script can also be run straight to the terminal while you write it:

```bash
./steps/env-snapshot.sh
```

That works because a step only ever prints to stdout - the runner owns the log,
the timestamps and the push. Keep it that way.

## 4. Verify

Three behaviours matter, and CI asserts all three (`toolkit` job). Run them by
hand after touching `caplib.sh`, `run.sh` or `agent.sh`, because they are the
ones whose failure is invisible until someone is waiting on the far side of a gap
for a log that never arrives:

- **Every captured line carries a UTC timestamp.** Header and footer are written
  outside `cap_run` and are exempt; everything between them is not.
- **A failing step still writes its footer, reports its real exit code, and is
  still committed.** A round trip through an operator must never be wasted by
  tooling that only reports success.
- **An unknown step exits 2 having written nothing**, and a gated step exits 3
  without `CONFIRM=yes`.

What nothing asserts: **a capture against a real remote machine.** No test here
runs an operator, an SSH hop, a flapping link or a locked-down git host, and
those are where the interesting failures live. Treating a green CI run as
evidence the loop works is the mistake this section exists to prevent.

## Where the content lives

`SKILL.md` is deliberately the short half.

| File | Contents |
|---|---|
| `skills/heliograph/SKILL.md` | the loop, the workflow, the hard rules |
| `skills/heliograph/references/method.md` | how to debug across a gap. The expensive lessons |
| `skills/heliograph/references/steps.md` | writing a step, and the traps that cost round trips |
| `skills/heliograph/references/runner.md` | every runner, `cap_*` function and knob |
| `skills/heliograph/references/transport.md` | how the control node authenticates to the git host |
| `skills/heliograph/references/remote-repo.md` | changing a repo that is also on the far side |
| `skills/heliograph/references/container.md` | running the loop in a container, and the honest limits |
| `skills/heliograph/scripts/bootstrap.sh` | installs the toolkit into a transport repo |
| `skills/heliograph/toolkit/` | the payload: runners, `lib/`, `steps/`, `docker/`, `TASK.md` |
| `skills/heliograph/toolkit/docker/` | the image, the entrypoint that clones, and the `docker run` wrapper |

A new hard-won lesson goes in `references/method.md` with the failure that taught
it. A new trap in writing steps goes in `references/steps.md`. Keep the rules
that outrank everything in `SKILL.md` itself - burying one a level down is how it
stops being obeyed.

## Working across machines

Editing anything under `~/dbhq-heliograph` is live immediately in Claude Code -
the skill directory is symlinked whole. For Codex, re-run `./install-codex.sh`
after a `SKILL.md` edit. If you develop on more than one machine, `git pull`
before you start and `git push` when done.
