#!/usr/bin/env bash
# =============================================================================
#  test-step-mode.sh - a step declares its mode, and an undeclared one refuses
# =============================================================================
# The gate used to be a list of step NAMES (`apply deploy destroy reset`), so a
# step called `cleanup-disk` was treated as a diagnostic whatever it did. The
# declaration now lives in the step file, and a step that does not carry one
# does not run at all.
#
# Fail-closed is the point, so the assertions below are as interested in the
# refusals as in the runs: an undeclared step must refuse, and it must say which
# file and which line would fix it, because the author is usually an agent on
# the other side of a round trip that costs a day.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
ROOT="$(cd "$HERE/.." && pwd)"
TOOLKIT="$ROOT/skills/heliograph/toolkit"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/transport"
"$ROOT/skills/heliograph/scripts/bootstrap.sh" "$REPO" >/dev/null 2>&1

# PUSH=0 throughout: this file is about the gate, not about git, and a step that
# reaches cap_push has already passed the thing under test.
run_step() {  # run_step [NAME=value...] ./run.sh <args...>; prints output, sets RC
  RC=0
  OUT="$( cd "$REPO" && PUSH=0 env "$@" 2>&1 )" || RC=$?
}

# --- --mode reports what a step declares, and does nothing else ---------------
run_step ./run.sh --mode env
assert_eq "--mode exits 0 for a known step" "0" "$RC"
assert_eq "the shipped baseline step declares read-only" "read-only" "$OUT"

run_step ./run.sh --mode net
assert_eq "the connectivity step declares read-only too" "read-only" "$OUT"

before="$( cd "$REPO" && ls ops-logs/ )"
run_step ./run.sh --mode env
after="$( cd "$REPO" && ls ops-logs/ )"
assert_eq "--mode writes no log: it is a question, not a run" "$before" "$after"

run_step ./run.sh --mode nosuchstep
assert_eq "--mode on an unknown step exits 2, like any unknown step" "2" "$RC"

# --- every shipped step declares a mode ---------------------------------------
# The guard that stops a new step shipping without one. A step file that reaches
# main undeclared would refuse to run on the far side, which is safe but reads
# as the toolkit being broken.
for s in "$TOOLKIT"/steps/*.sh "$TOOLKIT"/steps/*.ps1; do
  [ -f "$s" ] || continue
  case "${s##*/}" in _template.*) continue ;; esac
  m="$(sed -n 's/^#[[:space:]]*heliograph-mode:[[:space:]]*\([A-Za-z-]*\).*/\1/p' "$s" | head -1)"
  # Bracketed on both sides deliberately. Unbracketed, an EMPTY $m is a
  # substring of everything, so a step that declares nothing would pass the one
  # assertion written to catch it.
  assert_contains "shipped step ${s##*/} declares a mode" "[$m]" "[read-only] [action]"
done

# The templates must carry one as well: a step starts life as a copy of one, and
# a template without the line teaches every future step to omit it.
for t in "$TOOLKIT"/steps/_template.sh "$TOOLKIT"/steps/_template.ps1; do
  m="$(sed -n 's/^#[[:space:]]*heliograph-mode:[[:space:]]*\([A-Za-z-]*\).*/\1/p' "$t" | head -1)"
  assert_eq "template ${t##*/} carries the declaration" "read-only" "$m"
done

# --- an undeclared step refuses ----------------------------------------------
register() {  # register <name> <file> - add a step to the fixture's run.sh
  local name="$1" file="$2"
  ( cd "$REPO" && sed -i "s|^  # -- add task steps here.*|  ${name})  CMD=(./steps/${file}) ;;\n&|" run.sh )
}

cat > "$REPO/steps/undeclared.sh" <<'EOF'
#!/usr/bin/env bash
echo "this step forgot to say what it is"
EOF
chmod +x "$REPO/steps/undeclared.sh"
register undeclared undeclared.sh

run_step ./run.sh undeclared
assert_eq "an undeclared step refuses with 3" "3" "$RC"
assert_contains "and names the file to fix" "steps/undeclared.sh" "$OUT"
assert_contains "and quotes the line to add" "heliograph-mode:" "$OUT"
assert_eq "and it captured nothing on the way out" "$before" "$( cd "$REPO" && ls ops-logs/ )"

# A value that is neither of the two is not a near-miss to be forgiven: a step
# declaring `mode: readonly` or `mode: safe` has not made the statement the gate
# needs, and guessing which it meant is how a writing step gets waved through.
cat > "$REPO/steps/typo.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: readonly
echo "close, but not one of the two"
EOF
chmod +x "$REPO/steps/typo.sh"
register typo typo.sh

run_step ./run.sh typo
assert_eq "an unrecognised mode refuses too, rather than being guessed at" "3" "$RC"
assert_contains "and says what the two accepted values are" "read-only" "$OUT"

# --- an action step needs CONFIRM, a read-only one does not -------------------
cat > "$REPO/steps/act.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: action
echo "this one changes something"
EOF
chmod +x "$REPO/steps/act.sh"
register act act.sh

run_step ./run.sh act
assert_eq "an action step without CONFIRM refuses with 3" "3" "$RC"
assert_contains "and says exactly how to authorise it" "CONFIRM=yes" "$OUT"

run_step CONFIRM=yes ./run.sh act
assert_eq "with CONFIRM=yes it runs" "0" "$RC"
assert_contains "and the step really executed" "this one changes something" "$OUT"

run_step ./run.sh --mode act
assert_eq "--mode reports it as an action" "action" "$OUT"

# The name is no longer the gate. A step CALLED deploy that declares read-only
# runs without CONFIRM - which is the point: the file says what it is, and the
# filename stops being evidence about behaviour.
cat > "$REPO/steps/deploy.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: read-only
echo "named like an action, declared as a diagnostic"
EOF
chmod +x "$REPO/steps/deploy.sh"
register deploy deploy.sh

run_step ./run.sh deploy
assert_eq "a step named deploy that declares read-only runs on its declaration" "0" "$RC"

# ...and the converse, which is the one that matters. Under the old gate this
# step was invisible: nothing in `cleanup-disk` matches apply|deploy|destroy|reset.
cat > "$REPO/steps/cleanup-disk.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: action
echo "the step the name-based gate could not see"
EOF
chmod +x "$REPO/steps/cleanup-disk.sh"
register cleanup-disk cleanup-disk.sh

run_step ./run.sh cleanup-disk
assert_eq "a writing step with an innocent name is now gated" "3" "$RC"
assert_contains "and gated for the right reason" "CONFIRM=yes" "$OUT"

# A trailing comment after the value is ordinary - the shipped templates carry
# one - so the parse must stop at the value and not swallow the explanation.
cat > "$REPO/steps/trailing.sh" <<'EOF'
#!/usr/bin/env bash
# heliograph-mode: read-only     # measures, changes nothing
echo "declared with an explanation beside it"
EOF
chmod +x "$REPO/steps/trailing.sh"
register trailing trailing.sh

run_step ./run.sh --mode trailing
assert_eq "a trailing comment on the declaration line is tolerated" "read-only" "$OUT"

# --- the declaration is read from the step, not from run.sh -------------------
# Editing the step file alone must change the gate, with run.sh untouched.
sed -i 's/^# heliograph-mode: action/# heliograph-mode: read-only/' "$REPO/steps/cleanup-disk.sh"
run_step ./run.sh cleanup-disk
assert_eq "changing only the step's own header changes the gate" "0" "$RC"

t_summary
