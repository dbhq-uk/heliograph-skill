#!/usr/bin/env bash
# =============================================================================
#  intercom.sh - submit a step to a reachable agent, and read its log
# =============================================================================
#
#     export INTERCOM_URL=https://<your-function-app>.azurewebsites.net
#     export INTERCOM_KEY=<the function key>
#
#     ./intercom.sh run steps/net-probe.sh HOSTS="sql.example" PORTS=1433
#     ./intercom.sh poll  <taskId>          # one look
#     ./intercom.sh watch <taskId>          # until it settles
#     ./intercom.sh logs  <taskId>          # just the log, to stdout
#
#  WHEN TO USE THIS INSTEAD OF THE PIGEONHOLE. Only when the agent's endpoint is
#  reachable from here. That is unusual - the whole skill exists because it
#  normally is not - but an Azure Function App has a public HTTPS endpoint while
#  sitting inside the VNet, and when that is true the blob drop is indirection
#  with no purpose: credentials to hold, a timer interval to wait, four blob
#  operations to move text between two machines that can already talk.
#
#  THE SCRIPT GOES WITH THE REQUEST. There is no git on the far side, so a step
#  that arrived only by redeployment would turn a thirty-second loop into a
#  five-minute one. What that costs is stated plainly in references/intercom.md:
#  the mode header stops being a control, because the caller writes it, and the
#  function key plus the IP allowlist become the only real ones.
#
#  IT EXITS WITH THE STEP'S EXIT CODE, like run.sh, so this composes in a script.
#  A step that fails is a result: the log is still fetched, still written to
#  ops-logs/, and still printed.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-$HERE/ops-logs}"

# python3 for JSON, and this is not laziness. A step file contains quotes,
# backslashes and newlines by definition, and hand-rolled JSON escaping in bash
# gets one of them wrong eventually - producing a 400 that looks like the agent
# refusing the step rather than the client mangling it. jq would do as well but
# is present on fewer machines.
PY="${PY:-python3}"

die() { printf 'intercom: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || die "curl is not installed"
command -v "$PY" >/dev/null 2>&1 || die "$PY is not installed (set PY= to another python)"

URL="${INTERCOM_URL:-}"
KEY="${INTERCOM_KEY:-}"
[ -n "$URL" ] || die "set INTERCOM_URL to the Function App's base URL"
URL="${URL%/}"

# --- the two calls ------------------------------------------------------------
# Both send the key as a header rather than as ?code=, so it does not end up in
# a proxy log or a shell history line.

api() {   # api <method> <path> [body-file]
  local method="$1" path="$2" body="${3:-}" args=()
  args=(-sS -X "$method" -w '\n%{http_code}')
  [ -n "$KEY" ] && args+=(-H "x-functions-key: $KEY")
  if [ -n "$body" ]; then
    args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  fi
  curl "${args[@]}" "$URL$path"
}

# Reads {"status":...} out of a response body. Kept in one place so the field
# names appear once: the contract is in references/intercom.md and this is the
# only thing that has to agree with it.
field() {   # field <name> <<< json
  # `is None` rather than `or ""`, because the truthiness shortcut turned an
  # exit code of 0 into the empty string - so a step that SUCCEEDED reported
  # "exit none", which reads like the agent losing the result of the one run
  # that worked.
  "$PY" -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
    print("" if value is None else value)
except Exception:
    pass
' "$1"
}

# --- run ----------------------------------------------------------------------

cmd_run() {
  local script="${1:-}"; shift || true
  [ -n "$script" ] || die "usage: intercom.sh run <script-file> [KEY=VAL ...]"
  [ -r "$script" ] || die "cannot read $script"

  local name wait_for="${INTERCOM_WAIT:-25}"
  name="$(basename "$script")"; name="${name%.sh}"
  # The agent's own rule, applied here so a bad name is a local error rather
  # than a round trip: lowercase, and nothing that could be a path.
  name="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '-')"

  local body; body="$(mktemp)"
  # The env pairs arrive as arguments and are passed through as a JSON object,
  # so a value containing spaces survives. `env $ENV_EXTRA` unquoted is what
  # broke the pigeonhole: word splitting turned HOSTS="a b" into two arguments
  # and the run died before run.sh started, leaving no log at all.
  "$PY" - "$script" "$name" "$wait_for" "$@" > "$body" <<'PY'
import json, sys
path, name, wait, *pairs = sys.argv[1:]
env = {}
for pair in pairs:
    if "=" not in pair:
        sys.exit(f"intercom: expected KEY=VALUE, got {pair!r}")
    key, value = pair.split("=", 1)
    env[key] = value
with open(path, encoding="utf-8", errors="replace") as handle:
    script = handle.read()
json.dump({"name": name, "script": script, "env": env, "wait": int(wait)}, sys.stdout)
PY
  [ -s "$body" ] || { rm -f "$body"; die "could not build the request"; }

  local response code json
  response="$(api POST /api/run "$body")"
  rm -f "$body"
  code="$(printf '%s' "$response" | tail -1)"
  json="$(printf '%s' "$response" | sed '$d')"

  case "$code" in
    200|202) ;;
    400) die "refused: $(printf '%s' "$json" | field error)" ;;
    401|403) die "$code - the function key or the IP allowlist rejected this call" ;;
    *) die "HTTP $code: $json" ;;
  esac

  local task_id; task_id="$(printf '%s' "$json" | field taskId)"
  [ -n "$task_id" ] || die "no taskId in the response: $json"

  if [ "$code" = "202" ]; then
    printf 'intercom: %s is still running - polling\n' "$task_id" >&2
    [ "${INTERCOM_DETACH:-0}" = "1" ] && { printf '%s\n' "$task_id"; return 0; }
    cmd_watch "$task_id"
    return $?
  fi
  finish "$task_id" "$json"
}

# --- poll, watch, logs --------------------------------------------------------

get_task() {   # get_task <id> [offset]
  local response code body
  response="$(api GET "/api/task/$1?offset=${2:-0}")"
  code="$(printf '%s' "$response" | tail -1)"
  body="$(printf '%s' "$response" | sed '$d')"
  if [ "$code" != "200" ]; then
    printf 'intercom: HTTP %s from the agent: %s\n' "$code" "$body" >&2
    return 1
  fi
  # NOT JSON IS NOT A LOG. App Service answers "The service is unavailable."
  # in plain text while an instance is cold or recycling, and without this
  # check that sentence was written to ops-logs/ as though it were a capture,
  # and the client exited 0. A file that looks like evidence and is not is
  # worse than no file: the next reader has no way to tell.
  if ! printf '%s' "$body" | "$PY" -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf 'intercom: the agent did not return JSON (HTTP %s): %s\n' "$code" "$body" >&2
    return 1
  fi
  printf '%s' "$body"
}

cmd_poll() {
  local json; json="$(get_task "${1:?usage: intercom.sh poll <taskId>}")" || return 1
  printf 'status: %s  exit: %s  bytes: %s\n' \
    "$(printf '%s' "$json" | field status)" \
    "$(printf '%s' "$json" | field exit)" \
    "$(printf '%s' "$json" | field logBytes)"
}

cmd_watch() {
  local task_id="${1:?usage: intercom.sh watch <taskId>}" json status
  while :; do
    json="$(get_task "$task_id")" || return 1
    status="$(printf '%s' "$json" | field status)"
    case "$status" in
      # `timeout` settles too: the step was killed and the partial log IS the
      # answer, so waiting for `done` would wait for ever.
      done|refused|failed|timeout) finish "$task_id" "$json"; return $? ;;
    esac
    sleep "${INTERCOM_POLL:-2}"
  done
}

# THE WHOLE LOG, PAGED. `offset` walks it because the agent refuses to truncate:
# a log that came back short would be a log missing exactly the part worth
# reading, and there is no way for the reader to tell.
#
# It starts from a page the caller ALREADY HAS. The 200 from /api/run carries the
# first page with it, and re-fetching it was both a wasted round trip and a real
# failure: the second call could land on an instance that had gone cold, so a run
# that had already succeeded reported "The service is unavailable."
pages() {   # pages <id> <first-page-json> <outfile>
  local task_id="$1" json="$2" out="$3" next total
  : > "$out"
  while :; do
    printf '%s' "$json" | "$PY" -c 'import json,sys; sys.stdout.write(json.load(sys.stdin).get("log",""))' >> "$out"
    next="$(printf '%s' "$json" | field nextOffset)"
    total="$(printf '%s' "$json" | field logBytes)"
    [ -n "$next" ] && [ -n "$total" ] || return 0
    [ "$next" -ge "$total" ] && return 0
    json="$(get_task "$task_id" "$next")" || return 1
  done
}

cmd_logs() {
  local task_id="${1:?usage: intercom.sh logs <taskId>}" json tmp
  json="$(get_task "$task_id" 0)" || return 1
  tmp="$(mktemp)"
  pages "$task_id" "$json" "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp"; rm -f "$tmp"
}

# The log is kept as well as printed, in the same place and the same shape run.sh
# uses. A heliograph log is evidence; scrollback is not.
#
# Written to a temp file first and moved only on success, so a failed fetch
# leaves NO file in ops-logs/ rather than an empty or half one. A file that looks
# like evidence and is not is worse than no file at all.
finish() {   # finish <id> <first-page-json>
  local task_id="$1" json="$2" status exit_code stamp out tmp
  status="$(printf '%s' "$json" | field status)"
  exit_code="$(printf '%s' "$json" | field exit)"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  tmp="$(mktemp)"
  if ! pages "$task_id" "$json" "$tmp"; then
    rm -f "$tmp"
    printf 'intercom: %s %s, but its log could not be fetched\n' "$task_id" "$status" >&2
    return 1
  fi

  mkdir -p "$LOG_DIR"
  out="$LOG_DIR/$(printf '%s' "$json" | field name)-${stamp}.txt"
  mv "$tmp" "$out"
  cat "$out"

  printf '\nintercom: %s %s (exit %s)\n  %s\n' \
    "$task_id" "$status" "${exit_code:-none}" "$out" >&2
  [ "$status" = "done" ] || return 3
  return "${exit_code:-0}"
}

case "${1:-}" in
  run)   shift; cmd_run "$@" ;;
  poll)  shift; cmd_poll "$@" ;;
  watch) shift; cmd_watch "$@" ;;
  logs)  shift; cmd_logs "$@" ;;
  *)
    sed -n '3,14p' "$0" | sed 's/^# \{0,2\}//'
    exit 2 ;;
esac
