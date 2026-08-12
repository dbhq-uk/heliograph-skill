# Contributing

Thanks for your interest - contributions are welcome.

## Ways to help

- Report a bug or request a feature via [issues](https://github.com/dbhq-uk/heliograph-skill/issues)
- Add a generic step, a `lib/` helper, or a hard-won lesson to `references/method.md`, via a pull request

## Local development

```bash
git clone https://github.com/dbhq-uk/heliograph-skill.git
cd heliograph-skill
./install.sh          # symlinks into ~/.claude/skills (edits are live)
```

The whole skill directory is symlinked, so edits - to `SKILL.md`, `references/`,
`scripts/` and `toolkit/` alike - are live immediately. For Codex, re-run
`./install-codex.sh` after editing `SKILL.md`, since that one file is rewritten
at install time. Full walkthrough in [`docs/dev-setup.md`](docs/dev-setup.md).

## Before opening a PR

- `bash -n` over every shell script - they parse
- `claude plugin validate .` - the plugin validates
- Bootstrap a throwaway repo and run `PUSH=0 ./run.sh env` against it. Confirm
  every line of the log carries a UTC timestamp and the header names the branch
  and commit. Nothing automated asserts this
- Confirm a failing step still writes its footer, reports its real exit code, and
  is still committed
- British English, plain hyphens, no trailing full stops on headings

## The bar for a change to `toolkit/`

The toolkit runs on a machine you will never see, in front of someone who cannot
debug it, and each round trip is expensive. So:

**A change may not cost a round trip.** Anything that can hang without printing
first, prompt for input, or exit before writing the log is a regression however
much cleaner it reads. The five constraints in [`AGENTS.md`](AGENTS.md) are the
short version, and a PR that breaks one will be declined.

**A generic step, not your step.** `main` carries tooling that works anywhere.
A step naming hosts, environments, inventories or findings belongs on a task
branch in your own transport repo, never here. If a step of yours turned out to
be genuinely general, strip it of every local convention and send that.

**A lesson needs the failure that taught it.** `references/method.md` is a list
of rules that each cost something. A new rule should say what went wrong, in one
or two sentences, without naming an employer, a client or an estate. "A commit
step once reported success having never pushed" is the shape.

## What we will not accept

**Anything that grants access.** No tunnelling, no reverse shells, no proxying,
no holding a connection open, no credential harvesting. The whole premise is that
a person with legitimate access chooses to run each command, and the only thing
crossing the gap is a git commit. A pull request that turns this into a way
around an access control will be declined, and it is the one contribution that is
not a judgement call.

**Anything that reads a secret.** Naming a secret settles "does this exist here";
its value is never the question, and a log is permanent. Do not add a helper that
prints one, and do not weaken `cap_redact`. `secret.sh` is not an exception to
this: it carries a value you already hold *to* the far side as ciphertext, and
reads nothing off it.

**Real logs, real host names, real estates.** No `ops-logs/*.txt` from an actual
investigation, no internal DNS names, no client or employer names, and no
environment-specific defaults. Fixture-style examples are fine; a redacted real
one is not, because redaction fails quietly.

**A dependency.** Bash, git and GNU coreutils. A control node in a locked-down
environment often has no package manager you can use, no network route to a
registry, and no appetite for a change request. Anything that needs installing
cannot run where this is meant to run.

## Licence

By contributing you agree your work is licensed under the [MIT licence](LICENSE).
