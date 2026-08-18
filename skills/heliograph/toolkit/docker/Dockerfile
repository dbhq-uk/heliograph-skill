# =============================================================================
#  Dockerfile - somewhere the loop can live that is not somebody's laptop
# =============================================================================
# This image supplies only what start.sh's own preflight refuses to run
# without, plus git, openssh-client and sudo. Its ENTRYPOINT is entrypoint.sh
# (declared at the foot of this file): it clones a transport repo and hands
# over to that repo's own start.sh, which bootstrap.sh copies into every
# transport repo and which already owns the preflight, the credential
# resolution, the branch checkout and the handover to agent.sh. Duplicating
# any of that here would leave no answer to "which copy of the preflight is
# authoritative", so neither this file nor the entrypoint tries.
#
# Measured, not guessed - see task-1-report.md for the full method and for
# TWO DIFFERENT NUMBERS this daemon reports, which disagree by a wide
# margin and are both honest:
#   `docker image inspect --format '{{.Size}}'` (compressed layer size -
#   close to what a `docker pull` actually transfers, confirmed by diffing
#   against `docker save | gzip`):
#     debian:bookworm-slim                                       28.2 MB
#     + ca-certificates                                           3.5 MB
#     + git (pulls in perl, libcurl3-gnutls and their libraries) +30.1 MB
#     + openssh-client (pulls in libfido2, libcbor, krb5 libs)    +2.3 MB
#     + sudo                                                      +1.0 MB
#     finished image                                             ~65.2 MB
#
#   `docker images` / `docker system df -v` (unpacked, on-disk footprint
#   under this daemon's containerd snapshotter - what the image actually
#   occupies once built or pulled, no compression):
#     debian:bookworm-slim                                        116 MB
#     finished image                                               261 MB
#
# Which of these to quote depends entirely on the question being asked -
# "what does a pull cost" or "what does this take up once it is here" - so
# quote the one that answers the actual question and say which it is,
# rather than picking whichever number is smaller.
#
# bash (5.2), GNU sed (4.9, so -u is honoured), GNU coreutils (9.1, so
# base64 -w0 is genuinely unwrapped and not merely accepted), sha256sum, date
# and setsid all ship with debian:bookworm-slim already. Nothing is installed
# for any of them.
#
# WHY NOT ALPINE. It is smaller, but its sed is busybox's, and busybox sed
# REJECTS -u outright ("invalid option -- 'u'", exit 1) rather than silently
# ignoring it - so on Alpine as shipped, start.sh's preflight would correctly
# refuse to run at all. That refusal is the point: a sed that ignored -u
# instead of rejecting it would run buffered without complaint, producing a
# log where every captured line carries the same timestamp, which is worse
# than no timestamp because it looks like one. Reaching for musl's git
# instead of GNU sed does not even buy the size back: Alpine's own git
# package pulls in perl for the same reason Debian's does, so the ~30 MB cost
# below is not a saving Alpine actually offers.
FROM debian:bookworm-slim

# --- pinned by tag, not by digest ----------------------------------------------
# A digest pin buys byte-for-byte reproducibility at the cost of freezing out
# every security update Debian ships for bookworm from this point on, until
# someone notices the pin is stale and bumps it by hand. Nothing this image
# depends on - a bash new enough to have arrays, GNU sed, GNU coreutils - is
# something a bookworm point release would remove; what a point release
# WOULD change is exactly the security patching this image should keep
# getting. It carries no baked-in secret and nothing about it is sensitive to
# which day's point release it was built from, so the tag is the safer
# default here: every build picks up whatever bookworm-slim currently is.
# Reproducibility in the sense that actually matters for this PR - "the
# published image is what this file produces, not what version of this file
# was current on the day someone ran a push" - is what task 4's publish
# workflow exists to guarantee, by building from this repo rather than by
# freezing this line.
ENV DEBIAN_FRONTEND=noninteractive

# openssh-client is here because references/transport.md's own stated
# preference is SSH with a forwarded agent key ("nothing is stored on the
# control node and the push needs no credentials of its own"), over HTTPS
# with a token, which that document treats as the fallback. Shipping an
# image with no `ssh` binary at all would silently take that preferred path
# off the table and force every user onto the fallback - a capability gap
# the documentation would then be wrong about.
#
# Including the binary does not make SSH auth WORK everywhere it is
# present, and the next two things are true regardless of what task 2 or 3
# decide:
#   - SSH from inside this container needs an agent socket forwarded in
#     (bind-mounting $SSH_AUTH_SOCK, typically), which is task 3's wrapper's
#     job to offer, not this Dockerfile's;
#   - PR 4's Azure Container Instances path has nobody to forward an agent
#     FROM - there is no host session on the far side of an ACI deployment -
#     so that path is token-based over HTTPS regardless of what ships here.
# `openssh-client` only makes SSH possible where an agent exists to forward;
# it does not make it universal.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         ca-certificates \
         git \
         openssh-client \
         sudo \
    && rm -rf /var/lib/apt/lists/*

# --- an unprivileged user, with passwordless sudo -------------------------------
# NOT a security boundary, and nothing written about this image, here or
# later, should be read as claiming otherwise. Passwordless sudo inside a
# container is functionally equivalent to root: anyone who can run a command
# in here can become root at will with one `sudo`.
#
# What it buys instead:
#   - processes stay unprivileged unless they explicitly ask to escalate,
#     rather than starting privileged by default;
#   - a file written into a bind-mounted repo belongs to this user, not to
#     root - which is what would otherwise break the operator's own host-side
#     checkout the next time they touched it;
#   - the toolkit's own escalation path is exercised rather than degenerating.
#     caplib.sh's cap_sudo_precache probes `sudo -n true` and only prompts if
#     that fails; under root there is nothing to prompt for, so the check
#     means nothing. steps/env-snapshot.sh's "sudo (non-interactive)" probe is
#     the same shape: under root it always reports "available WITHOUT a
#     password", which is technically true and tells the operator nothing
#     about the machine this container is meant to simulate. A root container
#     is therefore a WORSE simulator of the far side, not a more convenient
#     one.
#
# The honest limit: passwordless sudo still does not exercise the case
# cap_sudo_precache was actually written for, which is sudo needing a
# password with none cached. No posture available inside a container covers
# that - it would need a real password prompt, which nothing here supplies -
# so this buys a better simulator, not a complete one.
#
# uid 1000 because it is the first normal uid on most Linux distributions and
# therefore the uid a bind-mounted host directory's own first user is likely
# to already have, which is what keeps files this container writes owned by
# the operator rather than landing as a stray numeric uid in `ls -l`.
#
# The username is "heliograph", not "operator": debian:bookworm-slim already
# defines a SYSTEM GROUP called operator (gid 37, the traditional Unix
# operator group), and useradd refuses to create a same-named user group
# alongside it (exit 9, "group operator exists"). Measured by actually
# running useradd, not assumed - see task-1-report.md.
ARG HELIOGRAPH_UID=1000
RUN useradd --create-home --uid "${HELIOGRAPH_UID}" --shell /bin/bash heliograph \
    && printf 'heliograph ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/heliograph \
    && chmod 0440 /etc/sudoers.d/heliograph \
    && visudo -cf /etc/sudoers.d/heliograph

# --- the entrypoint --------------------------------------------------------------
# Copied and made executable while still root, so it works regardless of
# whatever mode the file carried when it entered the build context (git
# preserves the executable bit through a clone, but a build context that
# arrived some other way - `docker build` from a tarball, a CI checkout with
# core.fileMode off - might not). entrypoint.sh: clone the
# transport repo the container is given, then hand over to that repo's own
# start.sh. It owns none of start.sh's job - the preflight, the credential
# table, the branch checkout, the handover to agent.sh - only the clone that
# has to happen before start.sh (and caplib.sh with it) exists to be run.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

USER heliograph
WORKDIR /home/heliograph

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
