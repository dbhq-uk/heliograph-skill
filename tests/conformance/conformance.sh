#!/usr/bin/env bash
# =============================================================================
#  conformance.sh - the executable form of the capture contract
# =============================================================================
# AGENTS.md constraint 3 says there is one implementation of the capture
# pattern. That is becoming one *specification* with several implementations:
# bash today, PowerShell after A8, and the same properties across every
# transport after A6. This file is that specification.
#
# It asserts properties, never internals. A driver supplies the implementation.
# Nothing here may reference caplib.sh, run.sh or any path inside the toolkit:
# the moment it does, it stops being a specification and becomes a second copy
# of one implementation.
#
# Usage: conformance.sh <driver.sh>
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../assert.sh disable=SC1091
. "$HERE/../assert.sh"

DRIVER="${1:?usage: conformance.sh <driver.sh>}"
[ -f "$DRIVER" ] || { printf 'no such driver: %s\n' "$DRIVER" >&2; exit 2; }
# shellcheck disable=SC1090
. "$DRIVER"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf '\n--- conformance: %s ---\n' "$(drv_name)"

# Timestamps are HH:MM:SS. Converted to seconds since midnight so gaps can be
# measured. Midnight rollover is handled by the caller adding 86400 when the
# second value is smaller than the first.
secs_of() {
  local t="$1" h m s
  h="${t%%:*}"; t="${t#*:}"; m="${t%%:*}"; s="${t#*:}"
  # 10# forces base 10, or 08 and 09 are read as invalid octal.
  printf '%s' "$(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))"
}

# The timestamp column of a captured log: the field before the first " | ".
# Header and footer lines carry no such separator and are skipped.
stamps_of() { grep ' | ' "$1" | sed 's/ | .*//'; }

# --- property 1: every captured line carries a DISTINCT UTC timestamp ---------
# This is the busybox failure, and it is the reason the whole suite exists. A
# `sed` without -u buffers, every line of the block is stamped when the buffer
# flushes, and the log reads perfectly while being useless: a hang and slow
# progress become indistinguishable, which is the single property these logs
# exist for.
if drv_supports capture; then
  cat > "$WORK/three-slow.sh" <<'EOS'
#!/usr/bin/env bash
echo first; sleep 1.1; echo second; sleep 1.1; echo third
EOS
  chmod +x "$WORK/three-slow.sh"
  drv_capture "$WORK/p1.log" "$WORK/three-slow.sh" >/dev/null 2>&1

  p1_all="$(stamps_of "$WORK/p1.log" | wc -l | tr -d ' ')"
  p1_uniq="$(stamps_of "$WORK/p1.log" | sort -u | wc -l | tr -d ' ')"

  assert_eq "p1: three captured lines" "3" "$p1_all"
  assert_eq "p1: three DISTINCT timestamps, so the capture is unbuffered" \
    "3" "$p1_uniq"
else
  t_skip "p1: driver does not support capture"
fi

# --- property 2: a real gap in the source appears as a gap in the log --------
# Distinct timestamps are not enough. Stamps could be distinct and still wrong,
# by being applied when a line is read from a buffer rather than when it was
# produced. A hang shows up as a gap in the timestamp column or it does not
# show up at all, so the gap has to be measured, not assumed.
if drv_supports capture; then
  cat > "$WORK/gap.sh" <<'EOS'
#!/usr/bin/env bash
echo before; sleep 3; echo after
EOS
  chmod +x "$WORK/gap.sh"
  drv_capture "$WORK/p2.log" "$WORK/gap.sh" >/dev/null 2>&1

  p2_first="$(stamps_of "$WORK/p2.log" | sed -n 1p)"
  p2_last="$(stamps_of "$WORK/p2.log" | sed -n 2p)"

  if [ -z "$p2_first" ] || [ -z "$p2_last" ]; then
    t_no "p2: expected two stamped lines, got [$p2_first] [$p2_last]"
  else
    p2_a="$(secs_of "$p2_first")"
    p2_b="$(secs_of "$p2_last")"
    # Midnight rollover: the second stamp is smaller only if the day turned.
    [ "$p2_b" -lt "$p2_a" ] && p2_b=$(( p2_b + 86400 ))
    p2_delta=$(( p2_b - p2_a ))

    # The upper bound is 8 rather than 4 because CI runners are slow and a
    # false failure here is worse than a loose bound. A buffered capture
    # yields 0, which the lower bound catches.
    if [ "$p2_delta" -ge 3 ] && [ "$p2_delta" -le 8 ]; then
      t_ok "p2: a 3s gap in the source is a ${p2_delta}s gap in the log"
    else
      t_no "p2: a 3s gap in the source became ${p2_delta}s in the log"
      printf '     wanted 3..8, log was:\n'; sed 's/^/     /' "$WORK/p2.log"
    fi
  fi
else
  t_skip "p2: driver does not support capture"
fi

# --- property 3: the step's real exit code survives the pipeline -------------
# The capture is a pipeline, so $? is the exit of the last stage (tee) and is
# almost always 0. PIPESTATUS[0] is what carries the truth. Getting this wrong
# publishes every failed run as a success, which is the most expensive possible
# defect here: a wasted round trip through someone who cannot debug the machine.
if drv_supports capture; then
  cat > "$WORK/rc42.sh" <<'EOS'
#!/usr/bin/env bash
echo working
exit 42
EOS
  chmod +x "$WORK/rc42.sh"
  drv_capture "$WORK/p3.log" "$WORK/rc42.sh" >/dev/null 2>&1
  assert_eq "p3: exit 42 survives the capture pipeline" "42" "$?"

  cat > "$WORK/rc0.sh" <<'EOS'
#!/usr/bin/env bash
echo working
EOS
  chmod +x "$WORK/rc0.sh"
  drv_capture "$WORK/p3ok.log" "$WORK/rc0.sh" >/dev/null 2>&1
  assert_eq "p3: exit 0 is still 0, so the check is not stuck on failure" \
    "0" "$?"
else
  t_skip "p3: driver does not support capture"
fi

# --- property 4: a failed run still writes a complete log --------------------
# AGENTS.md constraint 2. Each round trip through an operator is expensive and
# none may be wasted by tooling that only reports success. A failed run has to
# read as clearly as a passing one: same footer, real exit code, RESULT FAILED.
if drv_supports capture; then
  drv_capture "$WORK/p4.log" "$WORK/rc42.sh" >/dev/null 2>&1
  p4_body="$(cat "$WORK/p4.log" 2>/dev/null)"

  assert_contains "p4: a failed run still writes the footer" \
    "finished UTC" "$p4_body"
  assert_contains "p4: the footer carries the real exit code" \
    "exit code    : 42" "$p4_body"
  assert_contains "p4: the failure is named, not implied" \
    "RESULT       : FAILED" "$p4_body"
  assert_contains "p4: the output produced before the failure is kept" \
    "working" "$p4_body"

  drv_capture "$WORK/p4ok.log" "$WORK/rc0.sh" >/dev/null 2>&1
  assert_contains "p4: a passing run says OK, so RESULT is not hardcoded" \
    "RESULT       : OK" "$(cat "$WORK/p4ok.log" 2>/dev/null)"
else
  t_skip "p4: driver does not support capture"
fi

# --- properties 5 and 6: the gates fail closed -------------------------------
# A step that declares nothing does not run at all, and nothing runs as root.
# Both are checked here rather than only in test-step-mode.sh and
# test-root-refusal.sh because they must hold for EVERY implementation and
# every transport, not only for the one those tests happen to exercise.
#
# The steps are given to the runner BY PATH rather than registered in its case
# table. The path form exercises the same gate, and patching a case table from
# a test would couple this suite to one implementation's internals, which is
# exactly what the driver split exists to prevent.
if drv_supports gates; then
  P5="$WORK/repo"
  if drv_bootstrap "$P5"; then

    cat > "$P5/steps/undeclared.sh" <<'EOS'
#!/usr/bin/env bash
echo this step declares nothing
EOS
    cat > "$P5/steps/declared.sh" <<'EOS'
#!/usr/bin/env bash
# heliograph-mode: read-only
echo this step declares itself and measures nothing
EOS
    chmod +x "$P5/steps/undeclared.sh" "$P5/steps/declared.sh"

    p5_before="$(find "$P5/ops-logs" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')"
    drv_step "$P5" steps/undeclared.sh
    assert_eq "p5: an undeclared step exits 3" "3" "$?"
    p5_after="$(find "$P5/ops-logs" -name '*.txt' 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "p5: an undeclared step writes no log at all" \
      "$p5_before" "$p5_after"

    # The control: the same runner, the same path form, a step that DOES
    # declare itself. Without this, p5 would pass just as well if the runner
    # refused everything.
    drv_step "$P5" steps/declared.sh
    assert_eq "p5: a declared step runs, so the gate is not refusing everything" \
      "0" "$?"

    # A fake `id` answering 0 to `id -u`, deferring to the real one otherwise.
    # caplib's cap_refuse_root calls `id -u` rather than reading $EUID
    # specifically so this is possible without being root.
    mkdir -p "$WORK/fakebin"
    p6_real_id="$(command -v id)"
    cat > "$WORK/fakebin/id" <<EOF
#!/usr/bin/env bash
[ "\$*" = "-u" ] && { echo 0; exit 0; }
exec "$p6_real_id" "\$@"
EOF
    chmod +x "$WORK/fakebin/id"

    ( cd "$P5" && PATH="$WORK/fakebin:$PATH" PUSH=0 ./run.sh steps/declared.sh \
    ) >/dev/null 2>&1
    assert_eq "p6: the same step refuses with 5 when the account is root" \
      "5" "$?"
  else
    t_skip "p5/p6: could not bootstrap a transport repo"
  fi
else
  t_skip "p5/p6: driver does not support gates"
fi

# --- property 7: redaction is wired INTO the capture -------------------------
# test-redact.sh already exercises cap_redact directly and in more depth. This
# asserts something different and weaker on purpose: that redaction is actually
# on the capture path of this implementation. A correct redactor that a second
# implementation forgets to call is exactly the drift this suite exists for,
# and a unit test of the function cannot see it.
#
# Over-masking is asserted too. These logs are the only evidence anybody gets,
# and a redactor that eats ordinary output is its own failure.
if drv_supports capture; then
  cat > "$WORK/leaky.sh" <<'EOS'
#!/usr/bin/env bash
echo "password=hunter2correct"
echo "Authorization: Bearer eyJleUJTRUNSRVQi"
echo "cloning https://ci-user:glpat-LEAKEDTOKENVALUE@git.invalid/x.git"
echo "listening on port 8443 and exit code 0"
EOS
  chmod +x "$WORK/leaky.sh"
  drv_capture "$WORK/p7.log" "$WORK/leaky.sh" >/dev/null 2>&1
  p7_body="$(cat "$WORK/p7.log" 2>/dev/null)"

  assert_eq "p7: a password= value does not survive the capture" "0" \
    "$(printf '%s\n' "$p7_body" | grep -c 'hunter2correct')"
  assert_eq "p7: a Bearer token does not survive the capture" "0" \
    "$(printf '%s\n' "$p7_body" | grep -c 'eyJleUJTRUNSRVQi')"
  assert_eq "p7: a credential in a URL does not survive the capture" "0" \
    "$(printf '%s\n' "$p7_body" | grep -c 'glpat-LEAKEDTOKENVALUE')"
  assert_contains "p7: ordinary output is NOT masked, so evidence survives" \
    "listening on port 8443 and exit code 0" "$p7_body"
else
  t_skip "p7: driver does not support capture"
fi

t_summary
