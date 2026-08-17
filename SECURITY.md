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

`cap_redact` masks the obvious shapes on their way into a committed log:
`password=` / `token=` / `api_key=` / `client_secret=` style assignments,
`Bearer` and `Basic` authorization headers, and PEM private key blocks.

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
