#!/usr/bin/env bash
# =============================================================================
#  build.sh - the deployment package for the Function host
# =============================================================================
#
#     ./build.sh [output.zip]
#     az functionapp deployment source config-zip -g <rg> -n <app> --src output.zip
#
#  THE TOOLKIT IS FLATTENED INTO THE ROOT, and that is the layout the code
#  expects: function_app.py, run.sh and caplib.sh all sit beside each other in
#  the package, while in the repository this directory is two levels below them.
#  intercom.py finds the toolkit by looking for those two files rather than by
#  counting directories, so it works in both - but only if they are actually
#  here, which is what this script is for.
#
#  DEPENDENCIES ARE VENDORED rather than built remotely. A remote build needs
#  the platform to reach an index, and this host exists precisely for estates
#  where outbound is the thing that does not work. .python_packages/lib/
#  site-packages is where the Python worker looks.
#
#  BUILD ON PYTHON 3.12 to match runtime_version. Everything here is pure Python
#  except cryptography, which ships abi3 wheels and is therefore portable across
#  3.9+ - so a mismatch is survivable, but it is not worth discovering from a
#  worker that fails to import azure.identity at start-up.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLKIT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$PWD/heliograph-function.zip}"
PY="${PY:-python3.12}"

command -v "$PY" >/dev/null 2>&1 || PY=python3
command -v zip >/dev/null 2>&1 || { echo "zip is not installed" >&2; exit 1; }

[ -f "$TOOLKIT/run.sh" ] && [ -f "$TOOLKIT/caplib.sh" ] || {
  echo "not a heliograph toolkit: $TOOLKIT" >&2; exit 1; }

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# --- the app ------------------------------------------------------------------
cp "$HERE/function_app.py" "$HERE/intercom.py" "$HERE/store.py" \
   "$HERE/host.json" "$HERE/requirements.txt" "$BUILD/"

# --- the toolkit, flattened ---------------------------------------------------
# caprun.sh and secret.sh come too: a step may source either, and a missing one
# fails inside a capture where it reads as the step being broken.
for f in run.sh caplib.sh caprun.sh pigeonhole.sh intercom.sh secret.sh; do
  [ -f "$TOOLKIT/$f" ] && cp "$TOOLKIT/$f" "$BUILD/"
done
cp -r "$TOOLKIT/steps" "$TOOLKIT/lib" "$BUILD/"
chmod +x "$BUILD"/*.sh "$BUILD"/steps/*.sh 2>/dev/null || true

# --- dependencies -------------------------------------------------------------
"$PY" -m pip install --quiet --upgrade --target "$BUILD/.python_packages/lib/site-packages" \
  -r "$HERE/requirements.txt"

# --- the zip ------------------------------------------------------------------
rm -f "$OUT"
( cd "$BUILD" && zip -q -r "$OUT" . -x '*.pyc' '*__pycache__*' )

printf 'built %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
printf '  %s files\n' "$(unzip -l "$OUT" | tail -1 | awk '{print $2}')"
