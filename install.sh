#!/bin/bash
# Install the heliograph skill into ~/.claude/skills/ as a live symlink install.
#
# SKILL.md references scripts via ${CLAUDE_SKILL_DIR}, which Claude Code
# substitutes to the skill's own directory for personal, project, and plugin
# installs alike. So this script symlinks the whole skill directory into
# ~/.claude/skills/ - every edit (SKILL.md, references/, scripts/ AND the
# toolkit) is immediately live, with no per-file rewrite. Re-run only when you
# add a new skill directory.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_ROOT="$HOME/.claude/skills"

echo "=== heliograph skill installer (Claude Code) ==="
echo

# --- Dependencies ---
# Bash and git, both of which you already have if you are reading this. The
# toolkit deliberately needs nothing else: it runs on locked-down control nodes
# where installing a package is a change request, not a command.
echo "No dependencies beyond bash and git."
echo

# --- Install each skill in this repo as a full-directory symlink ---
mkdir -p "$SKILLS_ROOT"
for src in "$SCRIPT_DIR"/skills/*/; do
  src="${src%/}"
  name="$(basename "$src")"
  target="$SKILLS_ROOT/$name"
  echo "Installing '$name' -> $target"
  rm -rf "$target"            # replace any prior copy or partial-symlink install
  ln -sfn "$src" "$target"    # whole-directory symlink; ${CLAUDE_SKILL_DIR} resolves it
done

echo
echo "Installed as directory symlinks - all edits are live. Re-run only when adding a new skill."
echo
echo "No setup step, no API key, nothing further to configure."
echo
echo "Done. Try: 'heliograph: set up a transport repo for <the thing you cannot log into>'"
