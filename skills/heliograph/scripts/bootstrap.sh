#!/usr/bin/env bash
# =============================================================================
#  bootstrap.sh  -  drop the heliograph toolkit into a transport repo
# =============================================================================
#     bootstrap.sh <target-dir>
#
#  Copies start.sh, run.sh, agent.sh, caprun.sh, caplib.sh, secret.sh, lib/,
#  steps/, agent/, ops-logs/, secrets/ and TASK.md into <target-dir>, and installs
#  the toolkit's gitignore as <target-dir>/.gitignore.
#
#  THE TARGET SHOULD BE ITS OWN PRIVATE REPO, not this one and not a repo that
#  holds anything else. Captured logs are committed and pushed - that is how a
#  run escapes a machine nobody can reach - so whatever the operator's commands
#  print ends up in that repo's history permanently. A transport repo is
#  cheap to create and cheap to delete; a shared one is neither.
#
#  Nothing here is overwritten silently: an existing file is left alone and
#  reported, so re-running this to pick up a newer toolkit is safe.
# =============================================================================
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../toolkit" && pwd)"
TARGET="${1:-}"

if [ -z "$TARGET" ]; then
  echo "usage: $0 <target-dir>" >&2
  echo "  the target should be a fresh, PRIVATE repo - captured logs are committed to it" >&2
  exit 2
fi

mkdir -p "$TARGET" || exit 1
TARGET="$(cd "$TARGET" && pwd)"

if [ "$TARGET" = "$SRC" ]; then
  echo "refusing to bootstrap the toolkit over itself" >&2
  exit 2
fi

copied=0
skipped=0

# Walk the toolkit rather than `cp -R` the directory: this is what lets an
# existing file be reported instead of clobbered, and it is the case that
# matters - the second run of this script is usually an upgrade over a repo
# that already has a task in flight.
while IFS= read -r rel; do
  dest="$TARGET/$rel"
  # The toolkit ships its ignore and attributes files without a leading dot so
  # that they apply to the transport repo and not to the skill repo carrying
  # them. Restore the dot here.
  #
  # .gitattributes matters most on a repo that will be cloned on Windows: it
  # pins the working tree to LF whatever core.autocrlf says, and without it a
  # sourced caplib.sh loses `set -uo pipefail` without stopping. See the header
  # of toolkit/gitattributes.
  [ "$rel" = "gitignore" ] && dest="$TARGET/.gitignore"
  [ "$rel" = "gitattributes" ] && dest="$TARGET/.gitattributes"
  if [ -e "$dest" ]; then
    echo "  exists, left alone : ${dest#$TARGET/}"
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  cp -p "$SRC/$rel" "$dest"
  echo "  installed          : ${dest#$TARGET/}"
  copied=$((copied + 1))
done < <(cd "$SRC" && find . \
  \( -name '.terraform' -o -name '.git' -o -name 'node_modules' \) -prune -o \
  -type f -print | sed 's|^\./||' | sort)

# The prune is not tidiness. `terraform init` drops a provider binary into
# .terraform/ next to each template, and azurerm alone is over 300MB. Without
# this, a bootstrapped transport repo went from about 200KB to 913MB, and that
# repo gets cloned on a locked-down control node, sometimes over a link that is
# the reason this tool exists. Measured, not guessed.

echo
echo "heliograph: $copied file(s) installed, $skipped left alone, in $TARGET"

if [ ! -d "$TARGET/.git" ]; then
  echo
  echo "$TARGET is not a git repository yet, and git is the transport. Next:"
  echo "  cd $TARGET && git init && git add -A && git commit -m 'heliograph: transport repo'"
  echo "  then add a PRIVATE remote and push."
fi

echo
echo "Then, on the control node: git clone <remote> && ./run.sh env"
