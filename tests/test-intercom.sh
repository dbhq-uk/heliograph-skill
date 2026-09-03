#!/usr/bin/env bash
# =============================================================================
#  test-intercom.sh - the HTTP transport: its logic, and its operator client
# =============================================================================
# Two halves.
#
# The first runs tests/test_intercom.py, which drives intercom.py against a
# dictionary and genuinely executes run.sh through bash. It is Python because
# the code under test is, and stdlib unittest because this repository promises
# no packages.
#
# The second drives intercom.sh against a fake `curl` on PATH, backed by a temp
# directory. The properties worth asserting there are all about what the client
# puts on the wire and what it does with what comes back - a script containing
# quotes and newlines, an env value containing a space, a 202 that has to be
# followed, and a log too big for one page.
#
# THE ENV-VALUE-WITH-A-SPACE CASE is here for the same reason it is in
# test-pigeonhole.sh. `env $ENV_EXTRA` unquoted split HOSTS="a b" into two
# arguments, the run died with exit 127 before run.sh started, and there was no
# log at all - the worst shape a failure can take across a gap, because an
# unanswered request looks exactly like a step still running.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=assert.sh disable=SC1091
. "$HERE/assert.sh"
TOOLKIT="$(cd "$HERE/../skills/heliograph/toolkit" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- half one: the Python -----------------------------------------------------

if command -v python3 >/dev/null 2>&1; then
  if (cd "$HERE/.." && python3 -m unittest discover -s tests -p 'test_intercom.py' -q) \
       > "$TMP/py.out" 2>&1; then
    t_ok "test_intercom.py: $(sed -n 's/^Ran \([0-9]*\) tests.*/\1 assertions/p' "$TMP/py.out")"
  else
    t_no "test_intercom.py"
    sed 's/^/     /' "$TMP/py.out"
  fi
else
  t_skip "test_intercom.py - no python3"
fi

# --- half two: a fake curl ----------------------------------------------------
# It answers only the two calls intercom.sh makes. Request bodies and headers
# are recorded so the client can be asserted on rather than only its output.

make_fake_curl() {
  local bin="$1"
  mkdir -p "$bin"
  cat > "$bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
STORE="${FAKE_STORE:?}"
method="GET"; body=""; url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data-binary) body="${2#@}"; shift 2 ;;
    -H) printf '%s\n' "$2" >> "$STORE/headers"; shift 2 ;;
    -w) shift 2 ;;
    -sS|-s|-S|-f|-fsS) shift ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$method" "$url" >> "$STORE/calls"
path="${url#*://*/}"
if [ "$method" = "POST" ]; then
  [ -n "$body" ] && cp "$body" "$STORE/last-body.json"
  cat "$STORE/run.json"; printf '\n'; cat "$STORE/run.code"
  exit 0
fi
offset="0"
case "$path" in *offset=*) offset="${path#*offset=}"; offset="${offset%%&*}" ;; esac
if [ -f "$STORE/task-$offset.json" ]; then
  cat "$STORE/task-$offset.json"
else
  cat "$STORE/task.json"
fi
printf '\n200'
FAKE
  chmod +x "$bin/curl"
}

BIN="$TMP/bin"
make_fake_curl "$BIN"
export PATH="$BIN:$PATH"

# A step file with the characters that break hand-rolled JSON escaping.
STEP="$TMP/Probe-Thing.sh"
cat > "$STEP" <<'STEPEOF'
#!/usr/bin/env bash
# heliograph-mode: read-only
echo "a \"quoted\" thing and a backslash \\"
STEPEOF

new_store() {
  local store="$1"
  rm -rf "$store"; mkdir -p "$store"
  printf '200' > "$store/run.code"
  cat > "$store/run.json" <<'JSON'
{"taskId":"abc123","name":"probe-thing","status":"done","exit":0,
 "log":"captured output\n","offset":0,"nextOffset":16,"logBytes":16}
JSON
  cp "$store/run.json" "$store/task.json"
}

run_client() {   # run_client <store> <args...>
  local store="$1"; shift
  FAKE_STORE="$store" INTERCOM_URL="https://agent.example" INTERCOM_KEY="k-secret" \
    LOG_DIR="$store/logs" "$TOOLKIT/intercom.sh" "$@" 2>"$store/stderr"
}

# --- what goes on the wire ----------------------------------------------------

STORE="$TMP/s1"; new_store "$STORE"
OUT="$(run_client "$STORE" run "$STEP" HOSTS="a b" PORTS=1433)"; RC=$?

assert_eq "a finished step exits 0" "0" "$RC"
assert_contains "the log is printed" "captured output" "$OUT"

SENT_SCRIPT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["script"],end="")' "$STORE/last-body.json")"
assert_eq "the script is sent byte-for-byte" "$(cat "$STEP")" "$SENT_SCRIPT"

SENT_HOSTS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["env"]["HOSTS"])' "$STORE/last-body.json")"
assert_eq "an env value with a space survives" "a b" "$SENT_HOSTS"

SENT_NAME="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["name"])' "$STORE/last-body.json")"
assert_eq "the name is lowercased from the filename" "probe-thing" "$SENT_NAME"

assert_contains "the key travels as a header" "x-functions-key: k-secret" "$(cat "$STORE/headers")"
if grep -q 'code=' "$STORE/calls"; then
  t_no "the key is not in the URL"
else
  t_ok "the key is not in the URL"
fi

assert_contains "the log is kept, not only printed" "captured output" "$(cat "$STORE/logs"/*.txt)"

# --- a step that fails is still a result --------------------------------------

STORE="$TMP/s2"; new_store "$STORE"
cat > "$STORE/run.json" <<'JSON'
{"taskId":"abc123","name":"probe","status":"done","exit":7,
 "log":"it went wrong\n","offset":0,"nextOffset":14,"logBytes":14}
JSON
cp "$STORE/run.json" "$STORE/task.json"
OUT="$(run_client "$STORE" run "$STEP")"; RC=$?
assert_eq "the step's exit code is the client's" "7" "$RC"
assert_contains "and its log still came back" "it went wrong" "$OUT"

# --- a 202 is followed rather than reported -----------------------------------

STORE="$TMP/s3"; new_store "$STORE"
printf '202' > "$STORE/run.code"
cat > "$STORE/run.json" <<'JSON'
{"taskId":"slow1","name":"probe","status":"running","poll":"/api/task/slow1"}
JSON
cat > "$STORE/task.json" <<'JSON'
{"taskId":"slow1","name":"probe","status":"done","exit":0,
 "log":"finished later\n","offset":0,"nextOffset":15,"logBytes":15}
JSON
OUT="$(INTERCOM_POLL=0 run_client "$STORE" run "$STEP")"; RC=$?
assert_eq "a 202 is polled to completion" "0" "$RC"
assert_contains "and the late log is printed" "finished later" "$OUT"

# --- detaching leaves the id, and nothing else --------------------------------

STORE="$TMP/s4"; new_store "$STORE"
printf '202' > "$STORE/run.code"
cat > "$STORE/run.json" <<'JSON'
{"taskId":"slow2","name":"probe","status":"running"}
JSON
OUT="$(INTERCOM_DETACH=1 run_client "$STORE" run "$STEP")"
assert_eq "INTERCOM_DETACH prints the task id" "slow2" "$OUT"

# --- a long log is paged, and reassembles exactly ------------------------------
# NEVER TRUNCATE is the rule this asserts. A short log is worse than none: the
# reader cannot tell that the interesting part is the part that went missing.

STORE="$TMP/s5"; new_store "$STORE"
printf '202' > "$STORE/run.code"
cat > "$STORE/run.json" <<'JSON'
{"taskId":"big1","name":"probe","status":"running"}
JSON
python3 - "$STORE" <<'PY'
import json, sys
store = sys.argv[1]
whole = "".join(f"line {i}\n" for i in range(2000)).encode()
half = len(whole) // 2
for offset, chunk in ((0, whole[:half]), (half, whole[half:])):
    end = offset + len(chunk)
    with open(f"{store}/task-{offset}.json", "w") as handle:
        json.dump({"taskId": "big1", "name": "probe", "status": "done", "exit": 0,
                   "log": chunk.decode(), "offset": offset,
                   "nextOffset": end, "logBytes": len(whole)}, handle)
with open(f"{store}/expected.txt", "wb") as handle:
    handle.write(whole)
PY
cp "$STORE/task-0.json" "$STORE/task.json"
OUT="$(INTERCOM_POLL=0 run_client "$STORE" run "$STEP")"
assert_eq "a paged log reassembles byte-exactly" \
  "$(wc -c < "$STORE/expected.txt")" "$(printf '%s\n' "$OUT" | wc -c)"
assert_contains "its first line is there" "line 0" "$OUT"
assert_contains "and its last" "line 1999" "$OUT"

# --- refusals say which one it was --------------------------------------------

STORE="$TMP/s6"; new_store "$STORE"
printf '400' > "$STORE/run.code"
printf '{"error":"name must match ^[a-z0-9]"}' > "$STORE/run.json"
run_client "$STORE" run "$STEP" >/dev/null; RC=$?
assert_eq "a 400 is fatal" "1" "$RC"
assert_contains "and quotes the agent's reason" "name must match" "$(cat "$STORE/stderr")"

STORE="$TMP/s7"; new_store "$STORE"
printf '403' > "$STORE/run.code"
printf '{}' > "$STORE/run.json"
run_client "$STORE" run "$STEP" >/dev/null
assert_contains "403 names both controls" "allowlist" "$(cat "$STORE/stderr")"

# --- the client refuses locally what the agent would refuse remotely ----------

STORE="$TMP/s8"; new_store "$STORE"
run_client "$STORE" run "$TMP/does-not-exist.sh" >/dev/null; RC=$?
assert_eq "an unreadable step file is a local error" "1" "$RC"
if [ -f "$STORE/last-body.json" ]; then
  t_no "and nothing was sent"
else
  t_ok "and nothing was sent"
fi

STORE="$TMP/s9"; new_store "$STORE"
run_client "$STORE" run "$STEP" NOT_A_PAIR >/dev/null; RC=$?
assert_eq "a malformed env argument is refused before sending" "1" "$RC"

t_summary
