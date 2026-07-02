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
echo "### install.sh finished (exit $?)"
echo "### smd path: $(command -v smd || echo MISSING)"
/usr/local/bin/smd --help >/dev/null 2>&1 && echo "### smd works" || echo "### smd NOT working"
echo "### BOOTSTRAP DONE $(date -u)"
