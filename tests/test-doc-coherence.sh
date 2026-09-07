#!/usr/bin/env bash
# =============================================================================
#  test-doc-coherence.sh - the skill says what the toolkit does
# =============================================================================
# SKILL.md is read by an agent that will act on it without checking. So a number
# in it is not prose, it is an assertion about code that lives in another file
# and changes on its own schedule.
#
# The failure this prevents has a particular shape. Someone changes a default in
# station.sh for a good reason. Nothing breaks, every test passes, and the skill
# now tells an agent something that used to be true. The agent waits 60 seconds
# for a progress snapshot that is never coming, on a machine nobody can reach,
# and the round trip is spent finding out that the documentation lied.
#
# So every fact SKILL.md states about the toolkit is checked against the
# toolkit. If you change a default, this fails, and the fix is to change the
# sentence as well. That is the entire point: it is not here to be passed, it is
# here to make the two files move together.
#
# It checks only facts stated HERE. Near-side facts - CLI flags, MCP tool names
# - belong to the other repository and are checked there, against the binary
# that implements them, because a copy of them here would be the same drift
# wearing a different hat.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"

SKILL_DIR="$HERE/../skills/heliograph"
SKILL="$SKILL_DIR/SKILL.md"
TOOLKIT="$SKILL_DIR/toolkit"
STATION="$TOOLKIT/station.sh"

# --- the file has to exist before anything below means anything --------------
# Without this the greps below all find nothing and every assertion "passes" by
# looking at an empty string.
if [ ! -f "$SKILL" ] || [ ! -f "$STATION" ]; then
  t_no "SKILL.md and toolkit/station.sh are both present"
  t_summary
  exit 1
fi
t_ok "SKILL.md and toolkit/station.sh are both present"

# --- defaults ----------------------------------------------------------------
# Pulled OUT of the code rather than compared to a literal written twice. A
# constant repeated in the test is a third copy to drift.
progress_default="$(sed -n 's/^PROGRESS_EVERY="\${PROGRESS_EVERY:-\([0-9]*\)}".*/\1/p' "$STATION" | head -1)"
actions_default="$(sed -n 's/^ALLOW_ACTIONS="\${ALLOW_ACTIONS:-\([0-9]*\)}".*/\1/p' "$STATION" | head -1)"

assert_eq "station.sh has a PROGRESS_EVERY default the test can read" \
  "60" "$progress_default"

# SKILL.md states the interval in prose, twice. Both have to agree with the code.
skill_progress_claims="$(grep -c "every $progress_default seconds" "$SKILL")"
if [ "$skill_progress_claims" -ge 1 ]; then
  t_ok "SKILL.md's progress interval matches PROGRESS_EVERY=$progress_default"
else
  t_no "SKILL.md's progress interval matches PROGRESS_EVERY=$progress_default"
  printf '     station.sh defaults to %ss; SKILL.md does not say "every %s seconds" anywhere\n' \
    "$progress_default" "$progress_default"
  printf '     it currently says: %s\n' "$(grep -o "every [0-9]* seconds" "$SKILL" | sort -u | tr '\n' ' ')"
fi

# --- read-only by default ----------------------------------------------------
# The single most important claim in the file. An agent that believes the loop
# is read-only when it is not will propose a step it would not otherwise
# propose, and the operator has already agreed to run whatever arrives.
assert_eq "station.sh is read-only by default" "0" "$actions_default"
if grep -q "read-only by default" "$SKILL"; then
  t_ok "SKILL.md says the loop is read-only by default"
else
  t_no "SKILL.md says the loop is read-only by default"
fi

# --- the flag that opens the gate --------------------------------------------
for flag in --allow-actions --no-actions; do
  if grep -q -- "$flag)" "$STATION"; then
    t_ok "station.sh accepts $flag"
  else
    t_no "station.sh accepts $flag"
  fi
done
if grep -q -- "--allow-actions" "$SKILL"; then
  t_ok "SKILL.md names --allow-actions as the flag that permits an action"
else
  t_no "SKILL.md names --allow-actions as the flag that permits an action"
fi

# --- the confirmation string -------------------------------------------------
# SKILL.md tells the reader to put CONFIRM=yes in the request. If the station
# ever looked for a different string, the request would be refused and the
# reason would point at a spelling nobody could see from the near side.
if grep -q "CONFIRM=yes" "$SKILL" && grep -rq "CONFIRM" "$TOOLKIT/run.sh"; then
  t_ok "CONFIRM=yes appears in both SKILL.md and run.sh"
else
  t_no "CONFIRM=yes appears in both SKILL.md and run.sh"
fi

# --- the paths ---------------------------------------------------------------
# SKILL.md names these as the files the two sides write. They are the contract
# with the near-side CLI as well, which writes station/request by the same
# rules, so a rename here is a rename in two repositories.
for path in station/request station/status ops-logs; do
  in_skill=no; in_toolkit=no
  grep -q "$path" "$SKILL" && in_skill=yes
  grep -rq "$path" "$STATION" && in_toolkit=yes
  if [ "$in_skill" = yes ] && [ "$in_toolkit" = yes ]; then
    t_ok "$path is named in both SKILL.md and station.sh"
  else
    t_no "$path is named in both SKILL.md and station.sh"
    printf '     in SKILL.md: %s, in station.sh: %s\n' "$in_skill" "$in_toolkit"
  fi
done

# --- every script SKILL.md tells you to run has to be there ------------------
# A command in a skill is an instruction an agent will follow verbatim. One that
# points at a path that does not exist fails in front of the operator, which is
# the audience this repository most needs to keep.
while IFS= read -r rel; do
  if [ -e "$SKILL_DIR/$rel" ]; then
    t_ok "SKILL.md points at \${CLAUDE_SKILL_DIR}/$rel, which exists"
  else
    t_no "SKILL.md points at \${CLAUDE_SKILL_DIR}/$rel, which does not exist"
  fi
done < <(grep -o '\${CLAUDE_SKILL_DIR}/[A-Za-z0-9_./-]*' "$SKILL" \
           | sed 's|\${CLAUDE_SKILL_DIR}/||' | sort -u)

# --- links resolve, and nothing is orphaned ----------------------------------
# Two directions, because they fail differently. A dead link wastes a read. An
# orphan is worse: a reference nobody is routed to is one nobody maintains, and
# it goes stale silently while still looking authoritative when finally opened.
linked="$(grep -o '(references/[a-z-]*\.md)' "$SKILL" | tr -d '()' | sort -u)"
for rel in $linked; do
  if [ -f "$SKILL_DIR/$rel" ]; then
    t_ok "SKILL.md links $rel, which exists"
  else
    t_no "SKILL.md links $rel, which does not exist"
  fi
done

for f in "$SKILL_DIR"/references/*.md; do
  [ -f "$f" ] || continue
  rel="references/$(basename "$f")"
  case "$linked" in
    *"$rel"*) t_ok "$rel is reachable from SKILL.md" ;;
    *) t_no "$rel is reachable from SKILL.md"
       printf '     it exists but nothing links to it, so nobody will read it\n' ;;
  esac
done

# --- the near side is described, but not restated ----------------------------
# The skill has to say the CLI exists: an agent that does not know will
# hand-edit a request file when a command would have done it correctly.
#
# It must NOT restate the CLI's flags. Those live on the site, next to the
# binary that implements them. This asserts the boundary is where it was put:
# the site is linked, and the flag tables are not copied back in.
if grep -q "heliograph.dbhq.uk" "$SKILL"; then
  t_ok "SKILL.md links the site for near-side reference"
else
  t_no "SKILL.md links the site for near-side reference"
fi

# `--interval`, `--timeout` and `--min` are CLI-only flags with no station-side
# meaning. Finding one here means a flag table was copied in, which is the exact
# duplication the split between the two repositories exists to prevent.
copied=""
for f in --interval --timeout --min --transport; do
  grep -q -- "$f" "$SKILL" && copied="$copied $f"
done
if [ -z "$copied" ]; then
  t_ok "SKILL.md does not restate CLI-only flags"
else
  t_no "SKILL.md does not restate CLI-only flags"
  printf '     found:%s - these belong on the site, next to the binary\n' "$copied"
fi

# --- the term that was retired -----------------------------------------------
# `agent` retired as a heliograph term for the far-side loop. That loop is a
# station. The word itself is not banned and cannot be: this skill is read by an
# AI agent, is driven by one over MCP, and a forwarded ssh agent is a third
# thing entirely. All three keep the name.
#
# What is banned is the loop being called one, because the document is read in
# the one context where that ambiguity is most expensive - by an agent, about
# something that is not it.
#
# The senses are told apart by what else is on the line. That is a heuristic
# rather than a parser, and it is the right trade: it catches the copy-paste
# from an older draft, which is how the word actually comes back.
stray="$(grep -n '\bagent\b' "$SKILL" | grep -viE 'ssh|mcp|\bAI\b|agent key|coding agent' || true)"
if [ -z "$stray" ]; then
  t_ok "SKILL.md does not call the far-side loop an agent"
else
  t_no "SKILL.md does not call the far-side loop an agent"
  printf '     %s\n' "$stray"
fi

# --- the same rule, applied to the toolkit -----------------------------------
# The rename reached SKILL.md and references/ first; the toolkit's own comments
# came last, and this is what stops them drifting back.
#
# THE EXCLUSIONS ARE THE INTERESTING PART, and they are reasons rather than a
# mute list. Every one of these is `agent` meaning something that genuinely is
# an agent, or a name that cannot change without breaking a machine:
#
#   agent/request, agent/status, .agent-state, .agent-approved, .agent.lock,
#   .agent-service.pid
#       read by the compat shim for stations bootstrapped before the rename.
#       Those machines cannot be reached to be upgraded - that is the entire
#       premise of this tool - so renaming them breaks precisely the estates
#       the shim exists for.
#
#   the sentence in station.sh explaining the rename
#       it has to say the old word or it stops explaining anything.
#
#   blob_up agent, "requests, logs, status and agent"
#       a literal storage container name on accounts that already exist.
#
#   a forwarded ssh agent, an Azure DevOps build agent
#       that is what those things are called.
stray_toolkit="$(grep -rn '\bagents\?\b' "$TOOLKIT" --include='*.sh' --include='*.ps1' 2>/dev/null \
  | grep -viE 'ssh|forwarded|build agent|user-agent|blob_up agent|status and agent|/agent/|agent/request|agent/status|\.agent[-.]|agent-service|called the .agent.|vocabulary changed|agent key|agent holding|agent reachable|agent at all|agent will not be usable' \
  || true)"
if [ -z "$stray_toolkit" ]; then
  t_ok "the toolkit does not call the far-side loop an agent"
else
  t_no "the toolkit does not call the far-side loop an agent"
  printf '%s\n' "$stray_toolkit" | sed 's/^/     /'
fi

# And the compat shim's paths must still be there, because an over-eager rename
# of the kind above is exactly what would remove them - silently, and only
# visibly on a machine nobody can reach.
missing=""
for path in "agent/request" "agent/status" ".agent-state" ".agent-approved" ".agent.lock"; do
  grep -q -- "$path" "$STATION" || missing="$missing $path"
done
if [ -z "$missing" ]; then
  t_ok "the compat shim still reads every pre-rename path"
else
  t_no "the compat shim has lost:$missing"
  printf '     A station bootstrapped before the rename would go silently deaf.\n'
fi

t_summary
