# Security

## Reporting a vulnerability

Email <dan@dbhq.uk> rather than opening a public issue. Include what you found,
how to reproduce it, and what an attacker could do with it. You will get a first
response within 48 hours.

## What this skill does

Heliograph debugs a machine you cannot log into, through an operator who cannot
debug it, using a git repository as the transport in both directions. That design
has a consequence worth stating before anything else:

**Everything heliograph writes is committed and pushed.** Logs, command output,
environment snapshots. Git history is permanent and visible to everyone with read
access to the repository. Treat the repository as the audience for every byte a
step prints.

### The execution model, and what bounds it

A step is arbitrary shell. That is the point of the tool - anything you can
express as a command can be measured on a machine you cannot reach - and no
amount of wrapping changes it. What follows is what bounds it, stated plainly so
nobody has to infer it from the code.

**The account is the credential boundary.** heliograph holds no credentials of
its own: no cloud auth, no API keys, no tokens beyond the git remote. So the
honest answer to "what could this do to the estate" is "whatever the account
running it could do", and that is the boundary to write down before an
evaluation. `run.sh`, `caprun.sh`, `agent.sh` and `pigeonhole.sh` all **refuse to
run as root** unless `ALLOW_ROOT=1` says the image has no other user.

**A step declares what it is, in its own file.** Every step carries
`# heliograph-mode: read-only` or `# heliograph-mode: action` in its first 30
lines, and a step that declares neither does not run at all. An action needs
`CONFIRM=yes` as well. This used to be a list of step names, which meant
`cleanup-disk` was treated as a diagnostic whatever it did.

The declaration is a statement by the step's author, checked at the boundary. It
is not a sandbox: an author can declare `read-only` and then write `rm -rf`, and
nothing in a shell runner can prevent that. It makes the classification explicit
and machine-checked rather than inferred from a filename.

**The unattended loop is read-only by default.** `agent.sh` and `pigeonhole.sh`
refuse an action step unless started with `--allow-actions` /
`PIGEONHOLE_ALLOW_ACTIONS=1`. The refusal is published to `agent/status` with its
reason, so the far side learns within one poll rather than waiting out a round
trip.

**Optional pinning, for an estate that wants an allowlist.** `REQUIRE_PIN=1
./agent.sh` runs only files whose sha256 the operator approved with
`./agent.sh --pin`; a new or edited step is refused until it is approved again.
It is off by default because it makes every new step wait for the operator,
which is the relaying the loop exists to remove. It covers `run.sh`,
`caplib.sh`, `lib/*.sh` and `steps/*`. It does **not** cover `agent.sh`, which
self-updates on pull.

### Evaluating it without giving it anything

There is nothing to give it, which makes a first evaluation unusually cheap:

1. Create an unprivileged user with no sudo. That account is the whole blast
   radius.
2. `bootstrap.sh` a scratch transport repo, private, on a host you already own.
3. `./run.sh env` - the baseline step. It reads; it changes nothing.
4. Read the log it committed. That log is the entire product.

No cloud credentials, no API keys, no agent identity, nothing to rotate
afterwards.

### Network

The skill makes no calls of its own beyond `git`. It pushes to and pulls from
whichever remote you configure - your repository, your host. There is no DBHQ
endpoint, no telemetry and no third-party service in the path.

### Credentials

Two separate secrets, handled differently.

**The git token**, for pushing over HTTPS. Resolved in this order:

1. `GIT_AUTH_HEADER` - a complete header, if you would rather build it yourself
2. `GIT_TOKEN` in the environment
3. The first line of `GIT_TOKEN_FILE`, then `./.git-token`, then `~/.git-token`

It is passed to git via `http.extraHeader`, **not** embedded in the remote URL.
That matters: a token in a remote URL ends up in `.git/config`, the reflog, and
every `git remote -v` anyone runs. This approach keeps it out of all three.

**The encryption passphrase**, for `secret.sh`, at
`~/.heliograph-passphrase` (override with `PASSPHRASE_FILE`). Written under
`umask 077` and `chmod 600`, so it never exists world-readable even briefly.

### Carrying a secret across the gap

`secret.sh` exists because sometimes a value has to reach the far side and no
channel exists between the two machines except the repository itself. The value
travels as **ciphertext in the repository**; the passphrase travels separately
through a human channel.

Consequences to understand before using it:

- **`secret.sh rm <name>` forgets the value, it does not erase the history.**
  The ciphertext stays in every clone and every commit that carried it. Rotate
  the underlying credential rather than assuming removal undoes exposure
- The strength of the scheme is the strength of the passphrase and the secrecy
  of the human channel that carried it
- `secret.sh key show` prints a fingerprint so both sides can confirm they hold
  the same passphrase without either transmitting it

### Log redaction is a safety net, not a guarantee

`cap_redact` masks two kinds of shape on their way into a committed log.

By **position**: `password=` / `token=` / `api_key=` / `client_secret=` /
`AccountKey=` style assignments, a credential carried in a URL, an
`Authorization:` header with any scheme, and PEM private key blocks.

By **shape**, where a vendor publishes a prefix precisely so that scanners can
recognise it: GitHub (`ghp_`, `gho_`, `ghu_`, `ghs_`, `ghr_`, `github_pat_`),
AWS access key ids (`AKIA`, `ASIA`), Slack (`xox…`), GitLab (`glpat-`), `sk-`
style API keys, and JWTs.

It is a regex filter over a stream. It will not catch a secret in a shape it does
not recognise, and it cannot unmask what a command chose to print in an unusual
format. **Never deliberately run a command that prints a secret**, and do not
treat redaction as permission to be careless. `REDACT=0` disables it when masking
is hiding output you genuinely need.

By design, `secret_name=pw-foo` is **not** masked - the name of a Key Vault
secret is useful and harmless - while `admin_password=...` is.

### On disk

- Installs into `~/.claude/skills/heliograph` or `~/.codex`
- Reads `~/.git-token` and `~/.heliograph-passphrase` if present
- Writes logs into the working repository, which are then committed

## Suited to

Air-gapped, client-owned and change-controlled estates, where the constraint is
that you have no interactive access and the operator has no debugging skill. It
is not a remote shell and gives no live access to the target - each exchange is
a commit.
