#!/usr/bin/env bash
# =============================================================================
#  secret.sh  -  carry a secret across the gap without it entering git in clear
# =============================================================================
#
#     ./secret.sh key               define the passphrase (run this FIRST, both sides)
#     ./secret.sh key show          print its fingerprint, so both sides can compare
#     ./secret.sh put <name>        read a value from stdin, store it encrypted
#     ./secret.sh get <name>        decrypt to stdout (for $( ) capture)
#     ./secret.sh list              what is stored, names only
#     ./secret.sh check <name>      prove it decrypts, without printing it
#     ./secret.sh rm <name>         forget it (history still has the ciphertext)
#
# THE PROBLEM THIS SOLVES
#
# Sometimes a value has to reach the far side and no channel exists: the two
# sides share no identity, the secret store on one is not reachable from the
# other, and this repository is the only thing both can see. It is also
# committed and pushed, so anything written into it is permanent and visible to
# everyone with read access.
#
# So the value travels as ciphertext, and the passphrase travels through a human
# who types it on both machines. Git carries something useless on its own.
#
# This is the opposite direction to a log. Nothing here reads a secret off the
# far side: it sends one you already hold to a machine that needs it.
#
# HOW TO USE IT
#
#   1. Define the passphrase on BOTH machines:
#
#        ./secret.sh key            # prompts twice, hidden, writes 0600
#
#      Then compare the fingerprints it prints. They match only if the two
#      machines hold the same passphrase, and the fingerprint does not reveal
#      it, being 600k rounds of PBKDF2 hashed again and truncated. Comparing
#      fingerprints beats discovering a typo later, when a `get` fails on the
#      far side with nothing but "bad decrypt" to go on.
#
#   2. On the authoring side:
#
#        ./secret.sh put registry-pass          # paste the value, then ^D
#        git add secrets/ && git commit && git push
#
#   3. In a step on the far side, capture it, never echo it:
#
#        PASS="$("$HERE/../secret.sh" get registry-pass)"
#        export PASS
#        some-command --password-stdin <<<"$PASS"
#
# WHAT THIS IS AND IS NOT
#
# It is AES-256-CBC with PBKDF2 at 600k iterations and a random salt, which is
# adequate for moving a credential between two machines you control. It is not
# a secret manager: there is no rotation, no audit, no expiry. The ciphertext is
# in git history forever, so a passphrase that later leaks exposes every secret
# ever sent under it. Change the passphrase periodically, prefer short-lived and
# narrowly scoped credentials, and land the real secret in whatever store the
# far side has rather than leaving it here.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORE="${SECRET_STORE:-$HERE/secrets}"
PASSFILE="${PASSPHRASE_FILE:-$HOME/.heliograph-passphrase}"
ITER="${PBKDF2_ITER:-600000}"

die() { printf '%s\n' "$*" >&2; exit 1; }

# The passphrase file is the whole security boundary. If it is group- or
# world-readable, every secret this repository has ever carried is readable by
# anyone with an account on the box, which is worse than not encrypting at all
# because it looks safe.
check_passfile() {
  [ -r "$PASSFILE" ] || die "no passphrase file at $PASSFILE
Define it on BOTH machines, with the same value:
    ./secret.sh key"
  local mode; mode="$(stat -c '%a' "$PASSFILE" 2>/dev/null || echo '')"
  case "$mode" in
    600|400) ;;
    *) die "refusing: $PASSFILE is mode ${mode:-unknown}, must be 600 or 400
    chmod 600 $PASSFILE" ;;
  esac
  [ -s "$PASSFILE" ] || die "refusing: $PASSFILE is empty"
}

have_openssl() { command -v openssl >/dev/null 2>&1 || die "openssl not found"; }

usage() { sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

cmd="${1:-}"; name="${2:-}"
case "$cmd" in put|get|check|rm) [ -n "$name" ] || usage ;; list|key) ;; *) usage ;; esac
case "$cmd" in key) name="" ;; esac
case "$name" in *[!A-Za-z0-9._-]*) die "name must be [A-Za-z0-9._-] only: $name" ;; esac

FILE="$STORE/$name.enc"

# A fingerprint of the passphrase: derive a key from it with a FIXED salt, so
# both machines get the same answer, then hash that and show a short prefix.
#
# The fixed salt is what makes two machines comparable, and it is also why this
# value must never be treated as a password: it is a checksum for humans. It
# costs 600k PBKDF2 rounds to compute, so it is not a practical lever against a
# decent passphrase, but a weak one is guessable from it. Use a long passphrase.
fingerprint() {
  openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" -S 68656c696f677261 -P \
      -pass "file:$PASSFILE" 2>/dev/null \
    | sed -n 's/^key=//p' \
    | openssl dgst -sha256 \
    | sed 's/^.*= //' | cut -c1-12
}

case "$cmd" in
  key)
    have_openssl
    case "${2:-}" in
      show)
        check_passfile
        printf 'passphrase file : %s\n' "$PASSFILE"
        printf 'fingerprint     : %s\n' "$(fingerprint)"
        printf '\nCompare that with the other machine. Same fingerprint, same passphrase.\n'
        exit 0 ;;
      "") ;;
      *) die "usage: $0 key [show]" ;;
    esac

    # Refuse to silently replace an existing passphrase: everything already in
    # secrets/ was encrypted under the old one and becomes unreadable, and the
    # ciphertext stays in git history where nobody can fix it later.
    if [ -e "$PASSFILE" ]; then
      printf 'A passphrase already exists at %s (fingerprint %s).\n' "$PASSFILE" "$(fingerprint 2>/dev/null || echo unknown)" >&2
      printf 'Replacing it makes every secret already in %s unreadable.\n' "$STORE" >&2
      if [ -t 0 ]; then
        printf 'Type REPLACE to go ahead: ' >&2; read -r confirm
        [ "$confirm" = "REPLACE" ] || die "left unchanged"
      else
        die "refusing to replace it non-interactively; remove it first if you mean to"
      fi
    fi

    if [ -t 0 ]; then
      # Typed, never echoed, and asked twice: a typo here is not discovered
      # until a decrypt fails on the far side, by which time the value has been
      # committed and the ciphertext is permanent.
      printf 'Passphrase (not shown): ' >&2; read -rs p1; printf '\n' >&2
      printf 'Again to confirm      : ' >&2; read -rs p2; printf '\n' >&2
      [ "$p1" = "$p2" ] || die "they do not match, nothing written"
      [ -n "$p1" ] || die "refusing to use an empty passphrase"
    else
      # Non-interactive, for provisioning: printf '%s' "$pass" | ./secret.sh key
      p1="$(cat)"
      [ -n "$p1" ] || die "refusing to use an empty passphrase"
    fi

    # Applies however it arrived. A passphrase piped in for provisioning is no
    # less permanent than one typed at a prompt.
    case "${#p1}" in
      [1-9]|1[0-9]) printf 'WARNING: %s characters. This protects every secret this repo has\n' "${#p1}" >&2
                    printf '         ever carried, and the ciphertext in git is permanent.\n' >&2
                    printf '         Use a long passphrase.\n' >&2 ;;
    esac

    umask 077
    printf '%s' "$p1" > "$PASSFILE" || die "could not write $PASSFILE"
    chmod 600 "$PASSFILE"
    unset p1 p2
    printf '\nwritten         : %s (mode %s)\n' "$PASSFILE" "$(stat -c '%a' "$PASSFILE")" >&2
    printf 'fingerprint     : %s\n' "$(fingerprint)" >&2
    printf '\nRun the same command on the other machine and check the fingerprints match.\n' >&2
    exit 0 ;;

  put)
    have_openssl; check_passfile
    mkdir -p "$STORE"
    # Read from stdin so the value never appears in argv, where `ps` would show
    # it to every user on the box.
    if [ -t 0 ]; then printf 'Paste the value, then Ctrl-D:\n' >&2; fi
    VALUE="$(cat)"
    [ -n "$VALUE" ] || die "refusing to store an empty value"
    umask 077
    printf '%s' "$VALUE" \
      | openssl enc -aes-256-cbc -pbkdf2 -iter "$ITER" -salt -base64 -pass "file:$PASSFILE" \
      > "$FILE" || die "encryption failed"
    # Prove it round-trips now rather than discovering it on the far side, where
    # the only symptom would be a step failing for no visible reason.
    RT="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -base64 -pass "file:$PASSFILE" -in "$FILE" 2>/dev/null)"
    [ "$RT" = "$VALUE" ] || { rm -f "$FILE"; die "round-trip check failed, nothing stored"; }
    printf 'stored %s (%d bytes plaintext, %d bytes ciphertext)\n' "$name" "${#VALUE}" "$(wc -c < "$FILE")"
    printf 'commit it:  git add %s && git commit -m "secret: %s"\n' "${FILE#"$HERE"/}" "$name"
    ;;

  get)
    have_openssl; check_passfile
    [ -r "$FILE" ] || die "no such secret: $name (looked in $STORE)"
    # Buffered, not streamed. openssl writes partial plaintext to stdout before
    # it notices bad padding, so streaming a failed decrypt emits binary garbage
    # into whatever consumed it: a log, a secret store, a registry login.
    # Capture first, check the exit code, and only then emit.
    OUT="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -base64 -pass "file:$PASSFILE" -in "$FILE" 2>/dev/null)" \
      || die "decryption failed for $name, wrong passphrase on this machine?"
    [ -n "$OUT" ] || die "decrypted to nothing for $name, refusing to hand back an empty value"
    printf '%s' "$OUT"
    ;;

  check)
    have_openssl; check_passfile
    [ -r "$FILE" ] || die "no such secret: $name"
    V="$(openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -base64 -pass "file:$PASSFILE" -in "$FILE" 2>/dev/null)" \
      || die "$name: DECRYPT FAILED (wrong passphrase here?)"
    printf '%s: decrypts OK, %d bytes (value not shown)\n' "$name" "${#V}"
    ;;

  list)
    [ -d "$STORE" ] || { echo "(no secrets stored)"; exit 0; }
    found=0
    for f in "$STORE"/*.enc; do
      [ -e "$f" ] || continue
      found=1
      b="$(basename "$f" .enc)"
      printf '  %-32s %6s bytes  %s\n' "$b" "$(wc -c < "$f")" "$(date -u -r "$f" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || echo '')"
    done
    [ "$found" = "1" ] || echo "(no secrets stored)"
    ;;

  rm)
    [ -e "$FILE" ] || die "no such secret: $name"
    rm -f "$FILE"
    printf 'removed %s from the working tree.\n' "$name"
    printf 'NOTE: the ciphertext remains in git history. If the passphrase is\n'
    printf 'suspect, rotate the underlying credential rather than relying on this.\n'
    ;;
esac
