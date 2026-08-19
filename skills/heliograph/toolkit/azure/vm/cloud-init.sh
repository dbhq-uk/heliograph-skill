#!/usr/bin/env bash
# =============================================================================
#  cloud-init.sh - first-boot script for the heliograph VM host
# =============================================================================
#  Runs once, as root, via cloud-init's userdata handling (any cloud-init
#  image executes a customData payload starting with a #! shebang directly -
#  no cloud-config YAML needed). It is the ONLY thing this host installs:
#
#    1. git, ca-certificates - nothing else. bash, GNU sed, GNU coreutils and
#       setsid already ship on Ubuntu 24.04, so nothing else start.sh's own
#       preflight needs is missing.
#    2. an unprivileged "heliograph" user to run the agent as - never root,
#       for the same reason the Dockerfile does not run the container as
#       root: a captured log ends up owned by this user, not by root.
#    3. the clone itself, using the SAME env-based credential trick
#       toolkit/docker/entrypoint.sh uses (git_clone_with_header there) -
#       GIT_CONFIG_COUNT/KEY_0/VALUE_0 rather than `git -c
#       http.extraHeader=...`, so the token never appears in this process's
#       argv, which is exactly as readable via /proc/<pid>/cmdline on a bare
#       VM as it is inside a container.
#    4. a systemd unit so the agent survives a reboot and gets restarted if
#       it crashes - the VM's equivalent of ACI's `restartPolicy: OnFailure`.
#
#  THE CREDENTIAL ARRIVES THROUGH AZURE'S CUSTOM DATA, which is not a place
#  to put a secret you cannot rotate: anyone who can read this VM's own
#  resource definition (`az vm show`, `az vm get-instance-view`) can read the
#  base64 blob straight back out, in the same way ACI's plain environment
#  variable and the Web App's app setting can both be read back by anyone
#  who can read THOSE resources. The right fix - a managed identity reading
#  the token from Key Vault at boot, never putting it in custom data at all
#  - needs a Key Vault as a further piece of bring-your-own estate
#  infrastructure this template does not assume exists. Documented as a real
#  limitation, not fixed here: see references/azure.md.
#
#  THE CHECKOUT IS TRANSIENT precisely once: this script clones once, at
#  first boot. There is no persistent DATA DISK here and none is created -
#  the OS disk is the only disk, and re-running this template against the
#  same name recreates the VM (and the OS disk) from nothing. Git is still
#  the only thing that survives a rebuild, exactly as everywhere else in
#  this PR.
# =============================================================================
set -uo pipefail

# Templated in by bicep/terraform before this file is base64-encoded into
# customData - see main.bicep/main.tf. Left as plain shell variables (not
# environment variables set by the caller) because customData has no
# mechanism to pass a separate environment; the substitution happens on the
# CONTROL SIDE, before this script ever reaches the VM, so what lands in
# customData is already a complete, self-contained script.
REPO_URL="__REPO_URL__"
GIT_TOKEN="__GIT_TOKEN__"
GIT_TOKEN_USER="__GIT_TOKEN_USER__"
START_ARGS="__START_ARGS__"

LOG=/var/log/heliograph-cloud-init.log
exec > >(tee -a "$LOG") 2>&1

echo "$(date -u +%FT%TZ) heliograph cloud-init: starting"

apt-get update -y
# --no-install-recommends for the same reason the Dockerfile uses it: only
# what start.sh's own preflight actually checks for.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends git ca-certificates

if ! id heliograph >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash heliograph
fi

WORKDIR=/opt/heliograph/repo
mkdir -p /opt/heliograph
chown heliograph:heliograph /opt/heliograph

# git_clone_with_header - same shape as entrypoint.sh's function of the same
# name: the credential travels through GIT_CONFIG_COUNT/KEY_0/VALUE_0 so it
# never lands in this process's own argv. Run as the heliograph user so the
# clone - and everything under it - is owned by the user the systemd unit
# below actually runs as, not by root.
if [ -n "$GIT_TOKEN" ]; then
  AUTH_HEADER="Authorization: Basic $(printf '%s:%s' "$GIT_TOKEN_USER" "$GIT_TOKEN" | base64 -w0)"
  sudo -u heliograph env \
    GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=http.extraHeader \
    GIT_CONFIG_VALUE_0="$AUTH_HEADER" \
    git clone -- "$REPO_URL" "$WORKDIR"
else
  sudo -u heliograph git clone -- "$REPO_URL" "$WORKDIR"
fi

chmod +x "$WORKDIR/start.sh"

# The credential the RUNNING agent needs is separate from the one-off clone
# above: start.sh's own preflight and agent.sh's later pushes both re-read
# GIT_TOKEN/GIT_TOKEN_USER via caplib.sh's cap_git, the same env-based
# lookup as the clone. An EnvironmentFile, not inline Environment= lines in
# the unit, so the token is not visible in `systemctl cat` or
# `systemctl show` - only in this file, which is root:heliograph 0640.
install -d -m 0750 -o root -g heliograph /etc/heliograph
{
  printf 'GIT_TOKEN=%s\n' "$GIT_TOKEN"
  printf 'GIT_TOKEN_USER=%s\n' "$GIT_TOKEN_USER"
} > /etc/heliograph/env
chown root:heliograph /etc/heliograph/env
chmod 0640 /etc/heliograph/env

cat > /etc/systemd/system/heliograph.service <<UNIT
[Unit]
Description=heliograph agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=heliograph
WorkingDirectory=$WORKDIR
EnvironmentFile=/etc/heliograph/env
ExecStart=$WORKDIR/start.sh $START_ARGS
# OnFailure, not always-restart-unconditionally: same reasoning as ACI's
# restartPolicy in aci/main.bicep. A clean exit (stop: yes in agent/request,
# or --once finishing) must stay stopped.
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now heliograph.service

echo "$(date -u +%FT%TZ) heliograph cloud-init: done"
