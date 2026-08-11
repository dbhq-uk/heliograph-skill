#!/usr/bin/env bash
# =============================================================================
#  lib/terraform.sh - Terraform probes
# =============================================================================
# Read-only by design. There are deliberately NO destroy or `state rm` helpers
# here: those must be typed out by a human who means it, not reached for by a
# script that was set up days earlier and is now running unattended.
#
# TF_DIR selects the working directory (default: current directory).
# Everything runs -no-color -input=false so it can't hang on a prompt and the
# log stays readable.
# =============================================================================

TF_DIR="${TF_DIR:-.}"
TF_BIN="${TF_BIN:-terraform}"

_tf() { "$TF_BIN" -chdir="$TF_DIR" "$@"; }

tf_version()    { "$TF_BIN" version; }
tf_init()       { _tf init -input=false -no-color "$@"; }
tf_validate()   { _tf validate -no-color; }
tf_fmt_check()  { _tf fmt -check -recursive -no-color; }

# tf_plan [extra args...] - exit 2 from -detailed-exitcode means "changes",
# which is information, not failure. Translate it so a step doesn't read as
# broken just because drift exists.
tf_plan() {
  _tf plan -input=false -no-color -detailed-exitcode "$@"
  local rc=$?
  case "$rc" in
    0) echo "PLAN: no changes (infrastructure matches configuration)" ;;
    2) echo "PLAN: changes pending - see the plan above"; rc=0 ;;
    *) echo "PLAN: FAILED (exit $rc)" ;;
  esac
  return "$rc"
}

tf_state_list() { _tf state list; }
tf_output()     { _tf output -no-color "$@"; }
tf_show()       { _tf show -no-color "$@"; }

# tf_providers - which provider versions actually got locked in.
tf_providers()  { _tf providers; }

# tf_workspace - which workspace/state slice you are pointed at. Check this
# before believing a plan: the commonest "why is it proposing to destroy
# everything" answer is being in the wrong workspace or the wrong -chdir.
tf_workspace()  { _tf workspace show; }
