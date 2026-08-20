# The git host

Git is the transport, so how the control node authenticates to the remote is
load-bearing rather than incidental. Establish it once, at the start, and write
what you found into the branch.

## Prefer SSH with a forwarded agent key, IF someone stays logged in

Nothing is stored on the control node and the push needs no credentials of its
own. `cap_git` is then just `git`.

**This is the right answer only for an attended run**, and that qualifier is the
most important sentence on this page. A forwarded agent key exists only while
the operator's SSH session is open. The moment they disconnect, the key is gone.

So it is incompatible with `service.sh`, which exists precisely to let the loop
outlive that session. Install a service against a forwarded agent key and it will
start perfectly, poll happily, and fail every push. `service.sh` warns when it
sees this, but the warning is easy to skim past:

```
warn  origin is an SSH remote and this shell has an ssh-agent, which the
      service will NOT inherit.
```

## What an unattended loop needs instead

Pick whichever the estate allows. All three work with no change to `cap_git`.

**A key on disk**, the simplest. Generate it ON the control node so the private
half never travels, and register the public half with the host:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-keyscan -t ed25519 <host> >> ~/.ssh/known_hosts
```

`start.sh` will report `no ssh agent is reachable` and then let the read and
write checks settle it, which is the design working rather than a problem: a key
in `~/.ssh` needs no agent.

**A deploy key**, if the host has them and the estate permits them. Narrower than
anything else here, because it reaches exactly one repository.

The trap: on GitHub an **organisation** can disable them for every repo it owns,
and the refusal names the wrong scope:

```
Deploy keys are disabled for this repository
```

It is not a repository setting. It is `deploy_keys_enabled_for_repositories` on
the org, so looking through the repo's settings finds nothing to change. An owner
has to change it, or you use one of the other two.

**A token in a file.** `caplib` already reads `~/.git-token`, so a detached
service picks it up with nothing else to configure:

```bash
printf '%s' "$TOKEN" > ~/.git-token && chmod 600 ~/.git-token
```

Not the environment. A detached process inherits none of it, which is why
`service.sh` refuses to install when the only credential it can find is
`GIT_TOKEN` in the shell.



Confirm the **port** the host actually serves. A non-standard one is common on
self-hosted servers, and the wrong port typically times out rather than refusing,
so a config error presents as a network fault.

A host answering `remote: Shell access is not supported` is the **success** case:
the key was accepted and the server denies shell by design.

If auth fails on an SSH remote, check that `ssh-add -l` lists a key and that the
port is right, in that order.

## If you inherit an HTTPS clone

Expect it to fail on a locked-down node. There is often no usable credential
helper there, and several hosts reject the token-in-URL form outright, so the
push fails with a bare `Authentication failed` even when the token is valid.

`cap_git` attaches an explicit auth header instead. `_cap_auth_header` uses the
first of:

| | |
|---|---|
| `GIT_AUTH_HEADER` | used verbatim, e.g. a `Bearer` value, or anything else the host wants |
| `GIT_TOKEN` | sent as HTTP Basic, username `GIT_TOKEN_USER` |
| `GIT_TOKEN_FILE`, `./.git-token`, `~/.git-token` | first line of the file, same as above |

`GIT_TOKEN_USER` defaults to empty, which is what Azure DevOps expects. GitHub
wants `x-access-token`, GitLab `oauth2`. `.git-token` is gitignored.

**Re-pointing the remote at SSH is the right fix**, rather than carrying a header
forever.

### What the token path costs

The header is passed to git through the environment (`GIT_CONFIG_COUNT`), not on
the command line. `git -c http.extraHeader=...` would put the credential in
`/proc/<pid>/cmdline`, which is world readable, so any other user on the control
node could read it out of `ps`. The environment is owner-only.

Below git 2.31, or if the version cannot be read, there is no environment route,
so `cap_git` falls back to `-c` and the exposure returns. `./start.sh --check`
reports the git version, which is what tells you which of the two you are
getting.

Neither route hides the value from root, from a core dump, or from a debugger.
This is transport for a credential that should be short lived and narrowly
scoped, and re-pointing the remote at SSH remains the right fix rather than
carrying a header at all.

## The trap worth knowing

A token that works against the host's REST API tells you nothing about whether
git can authenticate. They are different credentials on different paths. Test the
one you need.

## The ref the preflight negotiates

Every `./start.sh` run, `--check` included, negotiates
`refs/heads/heliograph-write-check` with the remote. Anyone administering the git
host will see that name in an audit log, so it is worth being able to answer for
it.

It is a `git push --dry-run`. No ref is created, no objects are transferred and
nothing is left on the server. What it does is complete the handshake with
`git-receive-pack`, which is the service write access is granted on, and that is
the only way to establish that this credential may write before an hour-long run
captures a log it then cannot deliver. Read access is not write access, and
learning the difference afterwards costs a whole round trip through an operator
who cannot debug the machine.

The ref deliberately does not exist. A dry run against a branch that does exist is
refused locally as a non-fast-forward the moment the checkout is behind origin,
which is the ordinary state, and that refusal says nothing at all about the
credential.

It proves the credential is allowed to write. It does not prove a particular ref
would survive a `pre-receive` hook or a branch-name ruleset, because a dry run
sends no pack and those hooks never run.

The name is fixed rather than generated, and that is for the host's administrator
rather than for us: it is greppable, it carries the tool's name so nobody takes it
for someone's abandoned branch, and when the question comes the answer is the same
every time.

## If the push fails anyway

`cap_push` commits the log locally and prints the path. Nothing is lost; it needs
a manual `git push`. A failed push must never lose a log, which is why
`cap_push` does not exit on one.
