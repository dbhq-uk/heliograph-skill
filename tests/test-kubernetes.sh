#!/usr/bin/env bash
# =============================================================================
#  test-kubernetes.sh - the manifest, applied to a real cluster, running a step
# =============================================================================
# toolkit/kubernetes/heliograph.yaml shipped for months with no test and no
# cluster had ever run it. references/hosts.md called that "validated": the file
# is well-formed and reviewed, and nothing more was claimed.
#
# This is what it takes to say "proven" instead. A kind cluster, the real
# manifest, a station that clones a transport repo, runs a step and pushes the
# log back - checked for the properties the log is FOR, not merely for a pod
# that reached Running.
#
# WHAT IS PATCHED, AND WHY ONLY THAT
#
# Two values: the image, so a local build is used instead of a published tag,
# and REPO_URL, so it points at a git daemon in the cluster instead of a
# placeholder. Everything else - the replica count, the security context, the
# resource limits, the secret reference - is applied exactly as shipped. Patch
# more and the test stops being about the file somebody will actually apply.
#
# THE GIT DAEMON
#
# git:// needs no credential, which keeps a token out of a test fixture. The
# repository it serves is bootstrapped by this script, so the pod clones the
# same toolkit a real operator would.
#
# It SKIPS LOUDLY without kind, kubectl or a container runtime.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
REPO="$HERE/.."

# REACHABLE, not merely installed - and docker by name.
#
# This used to accept the binary being on PATH. With docker installed and its
# daemon stopped it selected docker anyway and the run died four steps later at
# "the toolkit image would not build", which blames the Dockerfile for a
# stopped daemon and sends whoever reads it to the wrong file entirely. The
# check belongs here, where the answer is still "your daemon is down".
#
# Docker specifically, because `kind load docker-image` below talks to docker's
# daemon whatever built the image. Naming podman as an alternative was never
# true for this file.
RUNTIME=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  RUNTIME=docker
fi

missing=""
hint=""
command -v kind >/dev/null 2>&1    || missing="$missing kind"
command -v kubectl >/dev/null 2>&1 || missing="$missing kubectl"
if [ -z "$RUNTIME" ]; then
  missing="$missing docker"
  # The distinction worth spending a line on: an absent docker is a machine
  # that was never going to run this, a stopped one is a machine that is two
  # words away from running it.
  if command -v docker >/dev/null 2>&1; then
    hint=" docker is installed but its daemon does not answer 'docker info' - try 'sudo systemctl start docker'."
  fi
fi
if [ -n "$missing" ]; then
  t_skip "missing:$missing. The Kubernetes manifest was NOT applied to any cluster.$hint"
  t_summary
  exit 0
fi

CLUSTER="heliograph-test-$$"
W="$(mktemp -d)"
PF=""

cleanup() {
  [ -n "$PF" ] && kill "$PF" 2>/dev/null
  kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT

say() { printf '\n--- %s\n' "$*"; }

# --- a transport repo, bootstrapped exactly as an operator would -------------
say "building a transport repo"
mkdir -p "$W/tr"
git -C "$W/tr" init -q .
git -C "$W/tr" config user.email ci@example.invalid
git -C "$W/tr" config user.name ci
bash "$REPO/skills/heliograph/scripts/bootstrap.sh" "$W/tr" >/dev/null 2>&1

# A step that reports what ran it. `heliograph-mode: read-only` is the exact
# spelling the station's gate requires; anything else is refused, which this
# test found out the hard way and is worth keeping right here.
cat > "$W/tr/steps/k8s-proof.sh" <<'STEP'
#!/usr/bin/env bash
# heliograph-mode: read-only
set -uo pipefail
echo "hostname: $(hostname)"
echo "whoami:   $(id -un) uid=$(id -u)"
# Deliberately spread over a few seconds. A buffered capture gives every line
# the SAME stamp, and a step that finishes inside one second cannot tell the
# difference - so the test would pass on a container that had destroyed the one
# property the log exists for.
sleep 2
echo "two seconds later"
sleep 2
echo "proof that a kubernetes pod ran this step"
STEP
chmod +x "$W/tr/steps/k8s-proof.sh"

# Registered as CMD=(...), not as a direct cap_run. station.sh asks
# `run.sh --mode <step>` before it will run anything, and an arm that calls
# cap_run itself bypasses the machinery that answers that - so the step is
# refused for declaring no mode, while the declaration is sitting right there
# in the file.
sed -i 's|^  env)  CMD=|  k8s-proof) CMD=(./steps/k8s-proof.sh) ;;\n  env)  CMD=|' "$W/tr/run.sh"

git -C "$W/tr" add -A >/dev/null 2>&1
git -C "$W/tr" commit -qm "transport repo" >/dev/null 2>&1
git -C "$W/tr" branch -M main >/dev/null 2>&1
git clone -q --bare "$W/tr" "$W/repo.git"

if [ -d "$W/repo.git" ]; then
  t_ok "a transport repo was bootstrapped and made bare"
else
  t_no "could not build the fixture repo"; t_summary; exit 1
fi

# --- images -------------------------------------------------------------------
say "building images with $RUNTIME"
if ! "$RUNTIME" build -q -t heliograph-toolkit:test \
      "$REPO/skills/heliograph/toolkit/docker" >/dev/null 2>&1; then
  t_no "the toolkit image would not build"; t_summary; exit 1
fi
t_ok "the toolkit image builds"

cat > "$W/Dockerfile.gitd" <<'EOF'
FROM heliograph-toolkit:test
USER root
COPY repo.git /srv/repo.git
RUN git -C /srv/repo.git config http.receivepack true \
 && chmod -R a+rwX /srv/repo.git \
 && touch /srv/repo.git/git-daemon-export-ok
ENTRYPOINT ["git","daemon","--export-all","--enable=receive-pack", \
            "--base-path=/srv","--reuseaddr","--listen=0.0.0.0","--port=9418","/srv"]
EOF
if ! ( cd "$W" && "$RUNTIME" build -q -t heliograph-gitd:test -f Dockerfile.gitd . ) >/dev/null 2>&1; then
  t_no "the git daemon image would not build"; t_summary; exit 1
fi
t_ok "a git daemon image was built around the fixture repo"

# --- cluster ------------------------------------------------------------------
say "creating a kind cluster"
if ! kind create cluster --name "$CLUSTER" --wait 180s >/dev/null 2>&1; then
  t_no "kind could not create a cluster"; t_summary; exit 1
fi
t_ok "a kind cluster is up"
KC=(kubectl --context "kind-$CLUSTER")

kind load docker-image heliograph-toolkit:test heliograph-gitd:test \
  --name "$CLUSTER" >/dev/null 2>&1

"${KC[@]}" apply -f - >/dev/null 2>&1 <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: gitd, labels: {app: gitd}}
spec:
  replicas: 1
  selector: {matchLabels: {app: gitd}}
  template:
    metadata: {labels: {app: gitd}}
    spec:
      containers:
        - name: gitd
          image: heliograph-gitd:test
          imagePullPolicy: Never
          ports: [{containerPort: 9418}]
---
apiVersion: v1
kind: Service
metadata: {name: gitd}
spec:
  selector: {app: gitd}
  ports: [{port: 9418, targetPort: 9418}]
EOF
if "${KC[@]}" wait --for=condition=available deploy/gitd --timeout=180s >/dev/null 2>&1; then
  t_ok "the git daemon is serving the transport repo"
else
  t_no "the git daemon never became available"; t_summary; exit 1
fi

# --- the real manifest, two values patched -----------------------------------
say "applying toolkit/kubernetes/heliograph.yaml"
sed -e 's|image: ghcr.io/dbhq-uk/heliograph-toolkit:.*|image: heliograph-toolkit:test\n          imagePullPolicy: Never|' \
    -e 's|value: "https://github.com/YOUR-ORG/YOUR-TRANSPORT-REPO.git"|value: "git://gitd/repo.git"|' \
    "$REPO/skills/heliograph/toolkit/kubernetes/heliograph.yaml" > "$W/applied.yaml"

# The manifest references this secret. git:// needs no credential, so the value
# is a placeholder - but the reference has to resolve or the pod will not start,
# and that is itself worth proving.
"${KC[@]}" create secret generic heliograph-git --from-literal=token=unused >/dev/null 2>&1

if "${KC[@]}" apply -f "$W/applied.yaml" >/dev/null 2>&1; then
  t_ok "the shipped manifest applies without modification beyond image and REPO_URL"
else
  t_no "kubectl rejected the manifest"
  "${KC[@]}" apply -f "$W/applied.yaml" 2>&1 | head -5
  t_summary; exit 1
fi

if "${KC[@]}" wait --for=condition=available deploy/heliograph --timeout=180s >/dev/null 2>&1; then
  t_ok "the deployment became available"
else
  t_no "the deployment never became available"
  "${KC[@]}" describe deploy/heliograph 2>&1 | tail -15
  t_summary; exit 1
fi

# --- the preflight passed inside the pod -------------------------------------
logs=""
for _ in $(seq 1 30); do
  logs="$("${KC[@]}" logs -l app=heliograph --tail=200 2>/dev/null)"
  printf '%s' "$logs" | grep -q "polling every" && break
  sleep 2
done
assert_contains "the station came up and is polling" "polling every" "$logs"
assert_contains "the preflight cleared inside the pod" "preflight: clear" "$logs"
# The gate is on by default wherever the loop runs. A host that quietly changed
# that would be the most expensive difference between two hosts imaginable.
assert_contains "state-changing steps are blocked by default in the cluster too" \
  "BLOCKED" "$logs"

# --- send a request and get a log back ---------------------------------------
say "sending a request"
"${KC[@]}" port-forward svc/gitd 19418:9418 >/dev/null 2>&1 &
PF=$!
sleep 4

git clone -q git://127.0.0.1:19418/repo.git "$W/ctl" 2>/dev/null
if [ ! -d "$W/ctl/.git" ]; then
  t_no "could not clone the fixture repo through the port-forward"; t_summary; exit 1
fi
git -C "$W/ctl" config user.email ci@example.invalid
git -C "$W/ctl" config user.name ci

id="$(date -u +%Y%m%dT%H%M%SZ)-k8s-proof"
mkdir -p "$W/ctl/station"
printf 'version: 1\nid: %s\nstep: k8s-proof\nenv:\ncancel:\nstop:\nnote: proving kubernetes\n' \
  "$id" > "$W/ctl/station/request"
git -C "$W/ctl" add -A >/dev/null 2>&1
git -C "$W/ctl" commit -qm "request: k8s-proof" >/dev/null 2>&1
# --rebase, because the station pushes its status to this branch far more often
# than we push a request, and a plain push loses the race.
git -C "$W/ctl" pull -q --rebase origin main >/dev/null 2>&1
if git -C "$W/ctl" push -q origin main >/dev/null 2>&1; then
  t_ok "a request was pushed to the transport repo"
else
  t_no "could not push the request"; t_summary; exit 1
fi

# --- the log comes back -------------------------------------------------------
say "waiting for the log"
log=""
for _ in $(seq 1 45); do
  git -C "$W/ctl" pull -q --rebase origin main >/dev/null 2>&1
  log="$(ls "$W/ctl"/ops-logs/k8s-proof-*.txt 2>/dev/null | head -1)"
  [ -n "$log" ] && break
  sleep 2
done

if [ -n "$log" ]; then
  t_ok "the station ran the step and pushed the log back"
else
  t_no "no log came back within 90s"
  "${KC[@]}" logs -l app=heliograph --tail=25 2>&1 | tail -25
  t_summary; exit 1
fi

body="$(cat "$log")"

# The properties the log is FOR. A pod that reached Running proves nothing; a
# log with these four properties is the whole product.
assert_contains "the step's own output is in the log" \
  "proof that a kubernetes pod ran this step" "$body"
assert_contains "the log records a clean exit" "exit code    : 0" "$body"
assert_contains "it ran as the unprivileged user the manifest asks for" "uid=1000" "$body"

# Every captured line carries a UTC timestamp. Without it a hang and slow
# progress are indistinguishable, which is the property the whole method rests
# on - and a container that buffered stdout would silently destroy it.
stamped="$(printf '%s\n' "$body" | grep -cE '^[0-9]{2}:[0-9]{2}:[0-9]{2} \| ')"
if [ "$stamped" -ge 3 ]; then
  t_ok "every captured line carries a UTC timestamp ($stamped lines)"
else
  t_no "only $stamped captured lines were timestamped: the pod buffered stdout"
fi

# Not all the same second. That is what a buffered capture looks like, and it
# reads like a working log.
# The step spans four seconds, so a working capture produces more than one
# stamp. All-identical stamps is exactly what a buffered pipe looks like, and it
# reads like a perfectly good log.
distinct="$(printf '%s\n' "$body" | grep -oE '^[0-9]{2}:[0-9]{2}:[0-9]{2}' | sort -u | wc -l)"
if [ "$distinct" -ge 2 ]; then
  t_ok "lines were stamped as they were produced ($distinct distinct timestamps)"
else
  t_no "every captured line carries the same timestamp: the pod buffered stdout"
  printf '     A log like this reads perfectly and cannot tell a hang from progress.\n'
fi

# The log is pushed BEFORE the closing status commit, so reading the status
# once, immediately after the log arrives, races the station and usually loses.
status=""
for _ in $(seq 1 20); do
  git -C "$W/ctl" pull -q --rebase origin main >/dev/null 2>&1
  status="$(cat "$W/ctl/station/status" 2>/dev/null)"
  printf '%s' "$status" | grep -qE '^state: *(idle|stopped)' && break
  sleep 2
done
if printf '%s' "$status" | grep -qE '^state: *idle'; then
  t_ok "the station published a terminal status"
else
  t_no "the station never returned to idle"
  printf '     %s\n' "$status"
fi
assert_contains "the status names the pod that ran it" "host:" "$status"

t_summary
