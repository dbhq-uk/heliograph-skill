#!/usr/bin/env bash
# =============================================================================
#  test-hosts.sh - every host template is accounted for, and says what it is
# =============================================================================
# toolkit/kubernetes/heliograph.yaml sat in this repository with no test, no
# mention in any document, and nothing saying whether it had ever been applied
# to a cluster. Ninety-one lines of confident YAML that somebody would sooner or
# later run against an estate they cannot easily debug, on the strength of it
# being here.
#
# That is the failure this file prevents, and it prevents it in the direction
# the mistake actually goes: a NEW template added without a status. Adding one
# is easy and satisfying; writing down that it has never been deployed is
# neither, so it is the step that gets skipped.
#
# It also checks the shape of the manifest itself, because "validated" is a
# claim references/hosts.md makes on its behalf and a claim nobody re-checks is
# a hope.
#
# WHAT THIS CANNOT DO, stated so nobody trusts it further than it goes. It
# cannot tell whether a host was really deployed. A row moved from validated to
# proven, with "deployed live" written beside it, passes - and should, because
# that claim is a person's word and there is nothing here to check it against.
# What it refuses is the cheap version: a new template with no row at all, a
# proven row citing a test file that does not exist, and a proven row with no
# evidence of any kind. Those are the ways the table rots by accident, which is
# how it will actually rot.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

SKILL_DIR="$HERE/../skills/heliograph"
HOSTS="$SKILL_DIR/references/hosts.md"
TOOLKIT="$SKILL_DIR/toolkit"
K8S="$TOOLKIT/kubernetes/heliograph.yaml"

if [ ! -f "$HOSTS" ]; then
  t_no "references/hosts.md exists"
  t_summary
  exit 1
fi
t_ok "references/hosts.md exists"

# --- every host template is in the table -------------------------------------
# DISCOVERED, not listed. The first version of this iterated a hardcoded list,
# which passed happily when a new template was added beside it - the exact
# failure the file claims to prevent, in a test asserting it was prevented. A
# list only ever checks the hosts somebody remembered to add to the list.
#
# So the tree is the source of truth: anything that looks like a host template
# has to appear in the table, including one added tomorrow by somebody who never
# reads this file.
hosts=""
for d in "$TOOLKIT"/azure/*/; do
  [ -d "$d" ] || continue
  # The function app is a transport (intercom), not a host for the loop. It is
  # excluded by name rather than by pattern so that the exclusion is visible.
  case "$(basename "$d")" in function) continue ;; esac
  hosts="$hosts toolkit/azure/$(basename "$d")"
done
for d in "$TOOLKIT"/docker "$TOOLKIT"/kubernetes; do
  [ -d "$d" ] && hosts="$hosts toolkit/$(basename "$d")"
done
for f in "$TOOLKIT"/service.sh "$TOOLKIT"/service.ps1; do
  [ -f "$f" ] && hosts="$hosts toolkit/$(basename "$f")"
done

for host in $hosts; do
  # The table names paths in backticks, or the host in prose. Match on the
  # distinctive last element rather than the whole path, because the table reads
  # better naming `toolkit/docker/` than the full path twice.
  leaf="$(basename "$host")"
  if grep -qi -- "$leaf" "$HOSTS"; then
    t_ok "$host has a row in references/hosts.md"
  else
    t_no "$host has a row in references/hosts.md"
    printf '     a template nobody documents is one somebody deploys blind\n'
  fi
done

# --- and every row carries a status ------------------------------------------
# The table is only worth having if every line commits to one of the two words.
rows="$(grep -c '^| .* | \*\*\(proven\|validated\)\*\* |' "$HOSTS")"
if [ "$rows" -ge 10 ]; then
  t_ok "the status table has $rows rows, each marked proven or validated"
else
  t_no "the status table has $rows rows marked proven or validated, expected at least 10"
fi

# Both words must actually be used. A table where everything is "proven" is the
# shape this file exists to prevent, and it would pass a check that only counted.
for word in proven validated; do
  if grep -q "\*\*$word\*\*" "$HOSTS"; then
    t_ok "the table uses '$word'"
  else
    t_no "the table uses '$word'"
  fi
done

# --- a claim of "proven" has to name evidence that exists --------------------
# No test can know whether a host really was deployed. What it CAN refuse is the
# cheap version of the lie: a row upgraded to proven whose evidence column names
# a test file that is not there.
#
# The rows proven by deployment say "deployed live" and are taken on trust,
# because that is what they are. The rows proven by CI name a file, and that
# file is checked.
while IFS= read -r line; do
  # Pull every tests/... path out of the evidence column.
  for f in $(printf '%s\n' "$line" | grep -o 'tests/[a-z0-9-]*\.sh'); do
    if [ -f "$HERE/../$f" ]; then
      t_ok "a proven row cites $f, which exists"
    else
      t_no "a proven row cites $f, which does not exist"
      printf '     %s\n' "$line"
    fi
  done
  # A proven row with neither a test file nor a live deployment is an assertion
  # with nothing behind it.
  if ! printf '%s\n' "$line" | grep -qE 'tests/|deployed live'; then
    t_no "a row claims proven with no evidence"
    printf '     %s\n' "$line"
  fi
done < <(grep '^| .* | \*\*proven\*\* |' "$HOSTS")

# --- the manifest is the shape the contract requires -------------------------
if [ ! -f "$K8S" ]; then
  t_skip "no kubernetes manifest in this tree"
else
  t_ok "toolkit/kubernetes/heliograph.yaml is present"

  # Parsed, not grepped. A manifest that does not parse is one kubectl rejects,
  # and "validated" would be a false claim.
  if command -v python3 >/dev/null 2>&1; then
    if python3 - "$K8S" <<'PY'
import sys
try:
    import yaml
except ImportError:
    sys.exit(3)          # no parser here; the grep checks below still run
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
if not docs:
    print("the manifest has no documents"); sys.exit(1)
kinds = [d.get("kind") for d in docs]
if "Deployment" not in kinds:
    print("no Deployment in the manifest, kinds are %s" % kinds); sys.exit(1)
# The contract says nothing needs to reach the station. A Service or an Ingress
# here would mean somebody opened a listener that nothing dials.
for bad in ("Service", "Ingress"):
    if bad in kinds:
        print("the manifest declares a %s; the station only ever dials out" % bad)
        sys.exit(1)
dep = docs[kinds.index("Deployment")]
spec = dep["spec"]["template"]["spec"]
if not spec.get("containers"):
    print("the Deployment has no containers"); sys.exit(1)
# One replica. Two stations on one lane both answer the same request and both
# push a log, and the second overwrites the first.
if dep["spec"].get("replicas", 1) != 1:
    print("replicas is %s; two stations on one lane race for the same request"
          % dep["spec"]["replicas"])
    sys.exit(1)
print("ok")
PY
    then
      t_ok "the manifest parses and matches the host contract"
    else
      rc=$?
      if [ "$rc" = "3" ]; then
        t_skip "python yaml is not installed; the manifest was not parsed"
      else
        t_no "the manifest parses and matches the host contract"
      fi
    fi
  else
    t_skip "no python3; the manifest was not parsed"
  fi

  # No PersistentVolumeClaim. Git is the persistence: a log is on local disk
  # only for the seconds between the capture finishing and the push landing.
  # A PVC here would suggest the checkout is meant to survive, which it is not.
  #
  # Checked as a DECLARATION, not as a string. The first version of this grepped
  # for the word and failed on the header comment explaining that there is no
  # PVC - a test that punishes the file for documenting the very property it is
  # asserting. Structure, not text.
  if grep -qE '^[[:space:]]*(kind:[[:space:]]*PersistentVolumeClaim|persistentVolumeClaim:)' "$K8S"; then
    t_no "the manifest declares no PersistentVolumeClaim"
  else
    t_ok "the manifest declares no PersistentVolumeClaim: git is the persistence"
  fi
fi

# --- the contract itself ------------------------------------------------------
# The five requirements are what makes this a contract rather than a list. If
# one is dropped, a host can satisfy the page while failing in the field.
for req in "writable checkout" "outbound" "credential" "unbuffered" "died"; do
  if grep -qi -- "$req" "$HOSTS"; then
    t_ok "the contract still requires: $req"
  else
    t_no "the contract still requires: $req"
  fi
done

# The unbuffered requirement is the one whose absence is invisible, so it is
# stated with its consequence rather than as a bare bullet.
if grep -qi "same timestamp" "$HOSTS"; then
  t_ok "the contract says what buffering does to a log"
else
  t_no "the contract says what buffering does to a log"
fi

# --- it is reachable ----------------------------------------------------------
# An unlinked reference is one nobody is routed to, which goes stale silently
# while still looking authoritative when somebody finally opens it. This is the
# same rule test-doc-coherence.sh applies to every other reference.
if grep -q "references/hosts.md" "$SKILL_DIR/SKILL.md"; then
  t_ok "SKILL.md links references/hosts.md"
else
  t_no "SKILL.md links references/hosts.md"
fi

t_summary
