# The container - somewhere the loop can live

`toolkit/docker/` is a third way to get `start.sh` running on a control node,
alongside "install bash/git/coreutils by hand" and "it's already there". It
exists for a node where installing anything is a change request but running a
container someone already built is not, or for an operator you would rather
hand one `docker run` line than a clone-and-run-a-script sequence.

It changes nothing about the loop itself. Once `start.sh` is running, this
document has nothing further to say - everything in `references/runner.md`,
`transport.md` and `secrets.md` applies exactly as it does on bare metal.

```
skills/heliograph/toolkit/docker/
  Dockerfile      the image
  entrypoint.sh   clones the transport repo, then execs start.sh
  heliograph.sh   the docker/podman run, turned into one command
```

Because `bootstrap.sh` copies the whole of `toolkit/` file by file, these
three files also land in every transport repo it sets up, alongside
`start.sh` and the rest. They do nothing there unless someone chooses to
build from that copy too - it is a side effect of a directory walk, not a
deliberate second distribution path, and worth knowing so it is not mistaken
for one.

## What ships in the image

`debian:bookworm-slim`, plus `ca-certificates`, `git`, `openssh-client` and
`sudo`, installed with `apt-get`. That is the whole package list. Bash, GNU
`sed`, GNU coreutils (`base64`, `sha256sum`, `date`), and `setsid` are not
installed by this Dockerfile at all - they already ship with
`debian:bookworm-slim`, in versions new enough for everything the toolkit
needs (`sed -u` honoured, `base64 -w0` genuinely unwrapped).

**Two honest size numbers, easily confused with each other:**

| | compressed (`docker image inspect --format '{{.Size}}'`) | on-disk (`docker images`) |
|---|---:|---:|
| `debian:bookworm-slim` (base) | 28.2 MB | 116 MB |
| finished image | 65.2 MB | 261 MB |

The compressed figure is what `docker image inspect` reports on this daemon,
and it tracks what a `docker pull` actually transfers - confirmed by diffing
it against `docker save | gzip`. The on-disk figure is what `docker images`
and `docker system df -v` report: the unpacked footprint this daemon's
containerd snapshotter actually occupies once the image is built or pulled,
with no compression. Both are real measurements of the same image, answering
different questions - "what does a pull cost" against "what does this take up
once it's here." Quote whichever one answers the question actually being
asked, and say which it is.

**`git` is the dominant cost**, not `openssh-client` or `sudo`: it pulls in
`perl` and its runtime for `git-am` and related subcommands, plus
`libcurl3-gnutls` and its own dependency chain, on the order of 30 MB by
itself. That is not a Debian packaging quirk to work around - Alpine's `git`
package pulls in `perl` for the identical reason, so reaching for it would
not buy the size back either.

**Why not Alpine.** Busybox `sed` on Alpine *rejects* `-u` outright
(`invalid option -- 'u'`, exit 1) rather than silently accepting and ignoring
it. On Alpine as shipped, that is a loud, immediate failure - the same
failure `start.sh`'s own preflight already exists to catch. It rules Alpine
out on this specific point without buying anything back on size, since
Alpine's `git` costs the same `perl` dependency Debian's does.

**Pinned by tag (`debian:bookworm-slim`), not by digest.** A digest pin buys
byte-for-byte reproducibility at the cost of freezing out every security
update Debian ships for bookworm from that point on. Nothing this image
depends on is something a bookworm point release would remove; what a point
release *would* change is exactly the patching this image should keep
getting. The reproducibility that actually matters here - "the published
image is what this Dockerfile produces, not what version of this file was
current on the day someone ran a push" - is what the publish workflow
guarantees by building from this repo on every publish, not something this
line needs to freeze.

## An unprivileged user, not a security boundary

The image runs as `heliograph`, an unprivileged user (`uid 1000` by default,
overridable at build time with `--build-arg HELIOGRAPH_UID=`) with
passwordless sudo. It is not called `operator`: `debian:bookworm-slim`
already defines a system group of that name (the traditional Unix operator
group, gid 37), and `useradd` refuses to create a same-named user group
alongside it.

**Say this plainly: it is not a security boundary.** Passwordless sudo inside
a container is functionally equivalent to root - anyone who can run a command
in here can become root at will with one `sudo`. Nothing here, or anywhere
else this image is described, should be read as claiming otherwise.

What it buys instead:

- Processes stay unprivileged unless they explicitly ask to escalate, rather
  than starting privileged by default.
- A file written into a bind-mounted checkout belongs to this user, not to
  root - which is what would otherwise break the operator's own host-side
  copy of it the next time they touched it.
- The toolkit's own escalation path is exercised rather than degenerating.
  `caplib.sh`'s `cap_sudo_precache` probes `sudo -n true` and only prompts if
  that fails; under root there would be nothing to prompt for, so the check
  would mean nothing. `steps/env-snapshot.sh`'s sudo probe is the same
  shape: under root it always reports "available WITHOUT a password",
  which is technically true and tells the operator nothing about the
  machine this container is meant to simulate.

**The honest limit:** passwordless sudo still does not exercise the case
`cap_sudo_precache` was actually written for - sudo needing a password with
none cached. No posture available inside this container covers that; it
would need a real password prompt, which nothing here supplies. This buys a
better simulator of the far side than a root container would, not a complete
one.

## The entrypoint: clone, then get out of the way

`entrypoint.sh` does three things, and is written to do nothing else:

1. Resolve a repository URL - a positional argument, or `REPO_URL` in the
   environment if none is given - and refuse to proceed without one.
2. Clone it into `${HELIOGRAPH_WORKDIR:-$HOME/repo}`, unless that directory
   already holds a clone of the *same* repo from an earlier run against a
   persistent volume, in which case it reuses that checkout unchanged.
3. `cd` in and `exec ./start.sh "$@"`.

Everything past the clone - the preflight, the credential table and its
reporting, the branch checkout, the handover to `agent.sh` - stays
`start.sh`'s job, unmodified. There is no `--branch` flag here: a branch to
switch to after the clone is `start.sh --branch`, reached only by passing it
through untouched. There is no second `git pull` for the reused-checkout
case either, even though `caplib.sh` genuinely is reachable by then (the repo
already exists on disk) - `start.sh` already runs its own `cap_git pull
--rebase --quiet` immediately before handing over to `agent.sh`, using the
same credential this container's environment provides, and adding a second
pull here would be exactly the "two copies, no authoritative one" problem
this whole toolkit is built to avoid.

**Both `REPO_URL` and a positional argument together are refused**, rather
than one silently winning - the ambiguity is real: is the first argument the
URL, or the first argument meant for `start.sh`?

**A URL carrying a credential (`https://user:token@host/...`) is refused
outright**, before any clone is attempted. That string would become an
argument to `git clone`, and `/proc/<pid>/cmdline` is world-readable inside
this container exactly as it is on a bare control node - the same reason
`cap_git` keeps a credential out of argv on the far side. Masking it on the
way out would not help: the leak into `/proc/<pid>/cmdline` has already
happened by the time anything gets printed.

**And the refusal comes too late to be the whole story, which it now says.**
By the time `entrypoint.sh` sees that URL it has been through several places
the container cannot reach back into: the shell that composed it, and that
shell's history; the *host's* process table while `docker run` parsed its own
command line; and `docker inspect`'s `.Config.Cmd`, which records it for as
long as the container exists and is readable by anyone who can talk to the
daemon. So the message says to **rotate the credential**, not merely to pass
it a safer way next time. The wrapper applies the same refusal *before* it
composes the runtime's command line, which is the only place the host-side
half of that exposure can still be prevented; `git@host` on an `ssh://` URL is
a username rather than a secret and is refused by neither.

### The credential for this one clone

Before the clone, `caplib.sh` - and with it `cap_git`, the one place this
toolkit is meant to attach a credential to git - does not exist yet, because
it lives inside the repo this script is about to clone. `entrypoint.sh`
carries a small, deliberate, narrow re-implementation of `cap_git`'s
env-not-argv trick, scoped to this one invocation, and never touches git
credentials again once the clone exists.

The precedence, first match wins:

| | |
|---|---|
| `GIT_AUTH_HEADER` | used verbatim |
| `GIT_TOKEN` | sent as HTTP Basic, username `GIT_TOKEN_USER` |
| `GIT_TOKEN_FILE` | first line of the named file |
| `~/.git-token` | same as above, if none of the above are set |

Same names, same order as `caplib.sh`'s own token resolution - narrower only
in that there is no `./.git-token` fallback, because there is no repo yet to
hold one. A `GIT_TOKEN_FILE` that is readable but yields nothing - a
*directory* (`GIT_TOKEN_FILE=/run/secrets`, the mount point rather than the
file inside it, is the realistic mistake) or a file whose first line is empty
- is reported as "unreadable or its first line is empty, so no header is
sent", `caplib.sh`'s own wording for the same state. Never "(0 chars)": that
would say the token is in force at the moment `git` is running with none. The header reaches `git clone` through the environment
(`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_N`/`GIT_CONFIG_VALUE_N`, appended at the
next free index rather than a hard-coded slot, so an operator's own ambient
git config survives alongside it), never through `-c` on argv and never
through the URL. Below git 2.31, or if the version cannot be read, there is
no environment route, so it falls back to `-c http.extraHeader=...` - the
same documented trade-off `cap_git` makes on the far side.

**`docker inspect` (and `podman inspect`) shows every `-e` value to anyone
who can talk to the daemon.** `GIT_TOKEN` and `GIT_AUTH_HEADER` passed with
`-e` are visible in it for the container's whole life - that is a property
of the runtime, not something this script or the wrapper can close from
inside the container. `GIT_TOKEN_FILE` naming a bind- or secret-mounted file
is the mitigation: only the path appears in `inspect` output, never the
value, and the wrapper's `--token-file` makes that the path of least
resistance rather than something an operator has to assemble by hand.

**The entrypoint's own progress lines carry a UTC time.** Everything after
the handover is stamped already (`run.sh`'s capture, `agent.sh`'s loop), but
nothing before `start.sh` was, and the gap the entrypoint owns is the clone:
on a large repo over a slow link, `docker logs` showed "cloning ..." and then
silence, which reads exactly like a hang. Two lines minutes apart settle it
from the log alone. `docker logs -t` stamps every line including `git`'s own
progress output, and is worth reaching for when a clone is the thing under
suspicion.

**`GIT_TERMINAL_PROMPT=0` is set and exported**, because a clone that blocks
on a username prompt is exactly the hang the toolkit's no-prompt rule exists
to prevent - `docker run -it` against an auth-required host with no working
credential and this unset sat past two minutes; with it set, the same clone
fails in about three seconds naming the reason.

### Restarting against a persistent volume

An already-cloned, already-recognisable checkout (`.git` present, `start.sh`
executable) is reused, never re-cloned: this container has no way to know
whether the previous run died mid-step with a commit or a captured log that
was never pushed, and a re-clone would silently discard that.

**A restart against a changed repository URL is refused**, not silently
honoured. The check is a plain, uncredentialed, local `git remote get-url
origin` against the checkout already on disk, compared with the URL this run
was given. Reusing the old checkout regardless would run `agent.sh` against,
and push captured logs to, the wrong transport repo - precisely the failure
this toolkit exists to prevent, so it is a refusal rather than a warning that
scrollback might miss.

**That check has three outcomes, and they are three different facts.** The
read succeeds and the URL matches, so the checkout is reused; the read
succeeds and the URL *differs*, so this is a genuinely different repository;
or the read *fails*, in which case the entrypoint knows nothing at all about
what the directory holds. All three refuse-or-reuse correctly, but only the
middle one may be described as "a clone of something else". The third is
reported as **unidentified**, with `git`'s own error quoted rather than
discarded.

A directory that cannot be **read or traversed at all** lands in the third
outcome too, and by a check made before anything else is inferred from its
contents. `[ -e "$WORKDIR/.git" ]`, `[ -x "$WORKDIR/start.sh" ]` and `ls -A`
all answer "no" and "empty" identically when the real answer is *permission
denied*, so a mode-`0700` checkout owned by another uid used to fall through
every branch to the clone, where `git`'s own accurate error was then
contradicted by a message blaming the URL or the credential. It is exactly
the shape the ownership diagnosis below exists for, and it was the one shape
that never reached it.

The commonest cause of the third is an **ownership mismatch**: `git` refuses
to read a repository owned by a different uid than the process reading it
(CVE-2022-24765, "dubious ownership"), which is exactly what a `--volume`
checkout owned by someone other than the container's `heliograph` user
produces. That case names itself as one, with the uid on each side, measured
from both the working tree and the `.git` directory because `git` refuses on
either. It explicitly does *not* claim the directory is a clone of some other
repository, because the failure that produced it is precisely the failure to
find that out.

**No message on a path that could not identify a directory ever suggests
emptying or deleting it.** That directory is the operator's own checkout and
may hold a captured log that was committed but never pushed - under
constraint 2 ("a failed run still ships, and a failed push never loses a
log"), that is the only copy of the evidence the toolkit exists to carry off
a machine nobody can reach. The unidentified paths say so explicitly and
offer remedies that keep the checkout: rebuild the image for the owning uid
(`--build-arg HELIOGRAPH_UID=`), `chown` the host directory to the
container's uid, or use rootless podman's `--userns=keep-id`, which the
wrapper already adds for you. Only the identified different-repository case
mentions emptying the directory at all, and it says to check for unpushed
work first.

A directory that is non-empty but not a recognisable checkout (no `.git`, or
no `start.sh`) is also refused, never deleted or cloned over - `git` would
refuse a non-empty target anyway, and inventing a "clear it first" behaviour
would be the wrong failure mode to choose when stopping and saying why is
right there.

## The two ways an image gets built

**Publish, on a pushed semver tag** (`v1.2.3`, matching `v*.*.*`) to GHCR.
Not on every push to `main` - that would turn every merge into a publish
event, with no announced version and no good answer to "which version did we
run" beyond a commit SHA. Not on a GitHub Release event either - a release
still needs a tag to exist first in GitHub's own flow, so gating on the tag
push already buys the same deliberateness without a second manual step or
the release event's extra permissions. A pushed tag is a deliberate act
distinct from an ordinary commit, maps one-to-one onto an exact commit and
therefore an exact `Dockerfile`, and is a version string an estate can write
into its own change record. The published image also carries OCI labels
(source repository, exact commit) so `docker inspect` on a pulled image
answers "which commit built this" with no git history in hand, and the
workflow's own run log records the image digest, which survives a tag later
being force-moved even though the tag itself is not immutable by
construction.

`latest` moves only for a tag with **no prerelease suffix**. `v1.2.3-rc1`
matches the `v*.*.*` trigger and is published under its own version, which is
useful; making it the image every estate pulls by default is not, and an
unconditional `latest` did exactly that. The trigger is left wide and the
`latest` tag is gated instead, so a release candidate ships without becoming
everybody's default.

**Build it yourself, from the same `Dockerfile`** this repo ships at
`skills/heliograph/toolkit/docker/Dockerfile` - the alternative for an
estate that will not pull a third-party image regardless of where it is
published. Nothing about the toolkit depends on which of the two produced
the image in front of you.

**The wrapper keeps those two paths apart, rather than blurring them.**
`heliograph.sh --image ghcr.io/org/heliograph-toolkit:v9.9.9` used to *build*
the local `Dockerfile` and tag the result with the published name - drift
reintroduced at the consumer end, in the one place nobody would look for it,
undoing the whole "the image at a tag can only be what that tag's commit
builds" argument above. A reference whose first segment looks like a registry
host (it contains a dot or a colon, or is `localhost`) is therefore **pulled**;
a pull that fails is a refusal, never a quiet fall back to building. `--build`
still builds such a tag, because that is an instruction rather than a guess,
and says what it is doing. `--ssh`'s derived `<image>-uid<N>` tag is the one
exception: no registry publishes it, so it is built locally and announced.

**Say plainly: the GitHub Actions side of this has never actually run.** The
GHCR login and push, the runner's Docker availability, and the tag-trigger
wiring are verified only by local reproduction of the same commands and
logic the workflow files contain - not by a real workflow run. Treat the
publish path as designed and locally rehearsed, not as proven.

## The wrapper

`heliograph.sh` turns a `docker run`/`podman run` into one line an operator
can be given, without adding a URL argument, a credential check or a
checkout-reuse decision of its own - all of that stays `entrypoint.sh`'s job,
unre-implemented. It detects whichever of `docker` or `podman` is on `PATH`
with a daemon or store that actually answers `info`, builds the image if it
is missing, and mounts nothing unless asked.

```
heliograph.sh [options] <repo-url> [-- start.sh args...]
```

| flag | does |
|---|---|
| `--detach`, `-d` | run detached and return; the default is foreground |
| `--volume HOSTDIR` | bind-mount `HOSTDIR` (**absolute path**) onto the checkout, so a restart reuses it instead of re-cloning - and so an unpushed log is already on the host |
| `--token-file PATH` | bind-mount `PATH` (**absolute path**) read-only and set `GIT_TOKEN_FILE` to it |
| `--ssh` | forward `$SSH_AUTH_SOCK`; build or reuse a uid-matched image |
| `--name NAME` | name the container; **defaulted** when not given |
| `--rm` | remove the container on exit even with no `--volume`, accepting the loss |
| `--print`, `--dry-run` | print the command instead of running it |
| `--build` / `--no-build` | force a rebuild, or refuse to build at all |
| `--runtime docker\|podman` | force a runtime instead of auto-detecting |

**Foreground by default.** The likeliest first-run failures - a bad
credential, an unreachable URL, a branch that does not exist - happen inside
the preflight, in the first few seconds, and a detached container that fails
at startup is invisible until an operator thinks to run `docker logs`.
`--detach` opts into the background shape once a run is known to be healthy.

**The container is kept on exit unless the checkout survives somewhere else.**
This is the correction of a real defect, so it is worth stating plainly rather
than as a preference. `--rm` used to be added to every foreground run, on the
reasoning that a removed container "loses nothing that matters, because what
matters already left over git". That traces only the success path. `cap_push`
exists for the other one: when the push cannot be made it commits the log
locally and prints *"PUSH FAILED - run `git push` manually. The file is
committed locally: `<path>`"*. With no `--volume`, that path is inside the
container, `--rm` deleted it the instant the process exited, and the printed
remedy named a checkout that no longer existed. The triggers are ordinary:
`--once`, `stop: yes`, Ctrl-C on the very first foreground run this document
recommends, `docker stop`, a reboot. Under constraint 2 - *a failed run still
ships, and a failed push never loses a log* - that is data loss, not untidiness.

So `--rm` is added only when the checkout is not the only copy:

- **`--volume HOSTDIR` given** (foreground): the checkout, including anything
  committed and not pushed, is on the host already, so the container goes.
- **`--rm` given explicitly**: the operator has said so, and the wrapper says
  back, before the run, what that costs.
- **otherwise the container is kept.** `--name` is defaulted (UTC stamp plus
  pid) so the wrapper can print, *before* the run starts, the exact command
  that recovers a log from it:

```
docker cp <name>:/home/heliograph/repo/ops-logs/ .
docker rm <name>          # once the log is somewhere safe
```

A detached container is kept regardless, as before - it is the case that most
needs `docker logs` afterwards.

**No mounts by default.** A plain run produces a container whose mount list is
empty. `--volume` persists the *whole* checkout across a restart, reusing
`entrypoint.sh`'s already-tested reuse/pull behaviour rather than inventing a
narrower mechanism for `ops-logs/` alone - and, since the fix above, it is
also the flag that puts a failed run's log on the host without a `cp`.

**Both mount flags require an absolute path.** `docker` and `podman` read a
bind-mount source that does not begin with `/` as a **named volume**, and
create it empty rather than refusing: `--token-file mytoken` mounted a new,
empty volume where the credential should have been (an unauthenticated clone,
and a credential line reporting an unreadable file), and `--volume somedir`
silently used something other than the directory the operator meant, so the
persistence promised in the row above did not hold. Both are refused by name.

**`REPO_URL` is not forwarded when a URL is also typed.** Every one of
`REPO_URL`, `GIT_TOKEN`, `GIT_AUTH_HEADER` and `GIT_TOKEN_USER` is forwarded
by bare name if it is exported - but `entrypoint.sh` refuses `REPO_URL` and a
positional argument together, so forwarding it regardless made a plain
`heliograph.sh <url>` die on a refusal naming a variable the operator had not
typed, telling them to "drop `REPO_URL`" when the wrapper had added it. The
typed URL wins, and a line on stderr says `REPO_URL` was left behind.

**Credential values never reach the wrapper's own command line.**
`REPO_URL`, `GIT_TOKEN`, `GIT_AUTH_HEADER` and `GIT_TOKEN_USER`, if already
exported in the operator's shell, are forwarded with bare `-e NAME` - never
`-e NAME=value` - so a value is never typed, logged in shell history, or
present in this script's own argv. `--token-file` is the path of least
resistance for a token: unlike `GIT_TOKEN`/`GIT_AUTH_HEADER` passed with
`-e`, its value never appears in `docker inspect`/`podman inspect` at all,
only the mounted path does.

### SSH forwarding and the ownership problem

`references/transport.md` states SSH with a forwarded agent key as the
preferred transport. `--ssh` is the one mount this wrapper does not treat as
optional to offer, because the image ships `openssh-client` on the stated
understanding that forwarding the socket in is the wrapper's job.

`ssh-agent`'s own socket is created mode `0600`, owned by whoever ran it -
`connect()` to it is refused to any other uid. Bind-mounting it unchanged
into a container whose `heliograph` user is a fixed uid only helps when the
operator's own uid happens to match. `--ssh` resolves the socket's actual
owning uid and builds, or reuses a cached build of, the image with
`--build-arg HELIOGRAPH_UID=<that-uid>`, tagged distinctly, so the
in-container `heliograph` user genuinely owns the uid the socket was created
under.

**Rootless podman needs one more thing: `--userns=keep-id`.** Rootless
podman's default user namespace remaps every non-root container uid to an
unrelated host uid, which breaks both `--ssh`'s uid-matching and `--volume`'s
reuse path - a host directory genuinely owned by the invoking user shows up
owned by something else entirely from inside the container, and `git`'s own
dubious-ownership refusal then blocks the checkout. `--userns=keep-id` is
podman's own documented fix, and the wrapper adds it whenever the runtime is
podman, never offered to Docker, which has no such flag and does not need
one - Docker does not remap uids by default.

**A limit this does not fully solve:** `--volume` has the identical ownership
problem, and `--ssh`'s uid-rebuilding machinery is not extended to it. It is
**diagnosed rather than solved**, deliberately, and the entrypoint's
unidentified-checkout message above is where that diagnosis lands: it names
the uid on each side and gives the exact `--build-arg HELIOGRAPH_UID=` line
for the uid that actually owns the directory. Three reasons not to automate
it further:

- A combined `--volume --ssh` run has two possibly different uids (the
  volume directory's owner, the socket's owner) and no principled way to
  choose between them. The wrapper does not guess.
- The two failures are not the same shape. An `ssh-agent` socket is mode
  `0600`, so a uid mismatch makes `--ssh` impossible, full stop; a `--volume`
  directory is usually mode `0755`, and what is actually needed is *write*
  access, which many host directories already grant to the container's uid.
- Auto-matching would silently choose which uid the container runs as from
  whatever happens to own a directory an operator pointed at. Selecting the
  container's user identity from an incidental property of a path is a
  surprise worth avoiding, especially for a system-owned directory.

Under podman, `--userns=keep-id` happens to cover the common `--volume` case
anyway, because it maps the container's uid to the invoking user's own rather
than to an arbitrarily chosen target the way `--ssh`'s build-arg does. It
does nothing for a directory owned by a third uid, and nothing at all under
Docker. In either remaining case the refusal now says exactly what to do:
build for the uid that matters by hand (`--image` naming your own tag,
`docker build --build-arg HELIOGRAPH_UID=...`), or chown the host directory
once.

## What none of this covers

- **The GitHub Actions publish path has never actually run.** Everything
  about it above is local reproduction of the same commands and logic the
  workflow files contain, or an explicit statement that a step is
  unverified. The GHCR login, the push itself, the runner's assumed Docker
  availability and the tag-trigger wiring against GitHub's real event
  payloads are all unproven beyond that.
- **The container is not a security boundary**, as above - repeated here
  because it is the fact most likely to be assumed rather than read.
- **`--volume` combined with `--ssh` at two different owning uids** is an
  unsolved combination, not a silently broken one - see above.
- **`--token-file` was not separately proven against podman.** Everything
  else that needs uid-matching was; this specific combination is judged
  lower risk (a plain read-only bind mount and an environment variable, with
  no uid-dependent logic of its own) rather than zero risk.
- **Azure Container Instances has no host session to forward an agent
  socket from.** `openssh-client` is present regardless, but that
  deployment path is token-based over HTTPS on its own terms; nothing here
  makes SSH forwarding universal, only possible where an agent exists to
  forward.
- **Nothing here exercises a capture against a real remote machine any
  differently than the toolkit already does without a container.** A
  container changes where `start.sh` runs, not what running it proves.
