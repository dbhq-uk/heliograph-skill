#!/usr/bin/env bash
# =============================================================================
#  assert.sh - assertions for the toolkit's tests
# =============================================================================
# No framework. bats would be a package, and this repo promises none. Source
# this, call the assertions, end with t_summary.
# =============================================================================

T_PASS=0
T_FAIL=0
T_SKIP=0

t_ok() { T_PASS=$((T_PASS + 1)); printf 'ok   %s\n' "$*"; }
t_no() { T_FAIL=$((T_FAIL + 1)); printf 'FAIL %s\n' "$*"; }

# t_skip - a section that did not run, COUNTED as well as printed.
#
# Skips used to be bare `printf 'skip ...'` lines invented per file. Two things
# went wrong with that. CI's guard against a silently unverified run greps for
# `^SKIP`, which caught only the whole-file banner test-container.sh prints
# before this file is even sourced - every per-section skip was lowercase and
# invisible to it, including the one guarding a Critical regression. And the
# summary line said "N passed, 0 failed" whether six sections ran or none did,
# which is exactly the reads-like-a-clean-run shape a loud skip must never
# have. So skipping goes through here: uppercase, so the grep sees it, and
# counted, so t_summary can report it and CI can refuse a non-zero count
# without knowing which sections exist.
t_skip() { T_SKIP=$((T_SKIP + 1)); printf 'SKIP %s\n' "$*"; }

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

# The skip count is always printed, including when it is zero: a reader
# scanning summary lines should be able to tell "nothing was skipped" from
# "this harness does not mention skips", and CI parses the same line rather
# than a per-file convention.
t_summary() {
  printf '\n%s: %s passed, %s failed, %s skipped\n' \
    "${0##*/}" "$T_PASS" "$T_FAIL" "$T_SKIP"
  [ "$T_FAIL" = "0" ]
}
