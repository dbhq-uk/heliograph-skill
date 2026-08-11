#!/bin/bash
# Install the heliograph skill into ~/.codex/skills/ for Codex.
#
# Codex does not substitute ${CLAUDE_SKILL_DIR}, so this script rewrites that
# variable to each skill's installed Codex path and symlinks the supporting
# directories (edits stay live). Re-run after editing a SKILL.md.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$HOME/.codex/skills"

echo "=== heliograph skill installer (Codex) ==="
echo

# See install.sh: bash and git, nothing else.
echo "No dependencies beyond bash and git."
echo

mkdir -p "$SKILLS_ROOT"
for src in "$SCRIPT_DIR"/skills/*/; do
  src="${src%/}"
  name="$(basename "$src")"
  target="$SKILLS_ROOT/$name"
  echo "Installing '$name' -> $target"
  mkdir -p "$target"
  # Clear what a previous install left before linking what this one needs.
  # Without this, an entry that has since been renamed or deleted upstream
  # survives as a symlink to a path that no longer exists - and a dangling
  # link fails more confusingly than a missing file, because it looks
  # installed. Only symlinks are removed, so a real SKILL.md is never at risk.
  find "$target" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +
  # Every directory SKILL.md can reference, so each one exists under the
  # rewritten path too. toolkit/ is here because bootstrap.sh copies out of it:
  # a Codex install that linked the script but not its payload would fail at the
  # first thing the skill does.
  for sub in references scripts toolkit; do
    [ -d "$src/$sub" ] && ln -sfn "$src/$sub" "$target/$sub"
  done
  sed "s#\${CLAUDE_SKILL_DIR}#$target#g" "$src/SKILL.md" > "$target/SKILL.md"
done

echo
echo "Installed for Codex. Re-run after editing a SKILL.md - that file is
rewritten at install time rather than symlinked, so its edits are not live."
echo
echo "Done. Try: 'heliograph: set up a transport repo for <the thing you cannot log into>'"
