#!/usr/bin/env bash
# =============================================================================
#  assert.sh - assertions for the toolkit's tests
# =============================================================================
# No framework. bats would be a package, and this repo promises none. Source
# this, call the assertions, end with t_summary.
# =============================================================================

T_PASS=0
T_FAIL=0

t_ok() { T_PASS=$((T_PASS + 1)); printf 'ok   %s\n' "$*"; }
t_no() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL %s\n' "$*"; }

# Values are printed in brackets so trailing whitespace is visible. A test that
# fails on an invisible difference wastes more time than no test.
assert_eq() {
  if [ "$2" = "$3" ]; then
    t_ok "$1"
  else
    t_no "$1"
    printf '     expected: [%s]\n     actual:   [%s]\n' "$2" "$3"
  fi
}

assert_contains() {
  case "$3" in
    *"$2"*) t_ok "$1" ;;
    *) t_no "$1"; printf '     wanted substring: [%s]\n     in: [%s]\n' "$2" "$3" ;;
  esac
}

t_summary() {
  printf '\n%s: %s passed, %s failed\n' "${0##*/}" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" = "0" ]
}
