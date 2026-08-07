#!/bin/bash
# Sigmond decoder VM template provisioning — stage 1: bootstrap smd.
# Runs inside the build VM as user 'build' (passwordless sudo). Logs to ~/provision.log.
set -e
exec > "$HOME/provision.log" 2>&1
echo "### $(date -u) bootstrap start on $(hostname)"
sudo mkdir -p /opt/git/sigmond
sudo chown "$(id -un)" /opt/git/sigmond
sudo apt-get update -qq && sudo apt-get install -y -qq git curl >/dev/null && echo "### git installed"
if [ ! -d /opt/git/sigmond/sigmond/.git ]; then
    git clone https://github.com/HamSCI/sigmond /opt/git/sigmond/sigmond
fi
cd /opt/git/sigmond/sigmond
echo "### sigmond @ $(git rev-parse --short HEAD); running install.sh ..."
SIGMOND_SKIP_PROXMOX_PROMPT=1 ./install.sh
sudo apt-get install -y -qq qemu-guest-agent >/dev/null 2>&1 && echo "### qemu-guest-agent installed"
sudo apt-get install -y -qq btop tmux >/dev/null 2>&1 && echo "### operator utils installed (btop tmux)"
# Health-check prerequisites.  sigmond's install.sh declares these too, but the
# image states them explicitly so its contents do not depend on installer
# ordering or on install.sh completing.  None of them announce their absence:
#   sqlite3  hf-timestd's pipeline-watchdog measures data freshness with it;
#            missing, it reads every table as stale and restarts healthy
#            services every 5 minutes (observed on B4 2026-08-07).
#   lsof     guards deletion of in-use data; missing, the guard fails OPEN.
#   bc       shell arithmetic; missing, substitutions yield an empty string.
# Report failure rather than swallowing it -- a silently missing prerequisite
# is exactly the defect this block exists to prevent.
if sudo apt-get install -y -qq sqlite3 lsof bc >/dev/null 2>&1; then
    echo "### health-check prerequisites installed (sqlite3 lsof bc)"
else
    echo "### ERROR: could not install health-check prerequisites (sqlite3 lsof bc)"
fi
echo "### install.sh finished (exit $?)"
echo "### smd path: $(command -v smd || echo MISSING)"
/usr/local/bin/smd --help >/dev/null 2>&1 && echo "### smd works" || echo "### smd NOT working"
echo "### BOOTSTRAP DONE $(date -u)"
