#!/bin/bash
# Sigmond decoder VM template provisioning — stage 2: install decoder components.
# Appends to ~/provision.log. Installs but does NOT start (template stays generalized).
# NB: smd must NOT be run under sudo — it self-elevates when a verb needs root.
exec >> "$HOME/provision.log" 2>&1
echo ""
echo "### $(date -u) COMPONENT install start (v2, no sudo on smd)"
sudo tee /etc/sigmond/topology.toml >/dev/null <<'EOF'
[component.radiod]
enabled = true
managed = true

[component.ka9q-web]
enabled = true

[component.wspr-recorder]
enabled = true

[component.psk-recorder]
enabled = true
EOF
echo "### topology enabled: radiod, ka9q-web, wspr-recorder, psk-recorder"
echo "### smd install  (self-elevates; compiles ka9q-radio — long) ..."
smd install --yes
RC=$?
echo "### smd install exit=$RC"
echo "### --- smd list ---"
smd list 2>&1 | head -30 || true
echo "### COMPONENTS DONE (rc=$RC) $(date -u)"

echo "### stage 3: capture-prep (scrub identity/secrets/data for golden image)"
sudo mkdir -p /etc/systemd/network
printf '[Match]\nName=en*\n\n[Network]\nDHCP=yes\n' | sudo tee /etc/systemd/network/99-dhcp-en.network >/dev/null
sudo systemctl enable systemd-networkd >/dev/null 2>&1
echo "### catch-all DHCP network config baked (en*)"
sudo cloud-init clean --logs 2>/dev/null; echo "### cloud-init cleaned"
smd admin capture-prep --yes
echo "### capture-prep exit=$?"
smd admin readiness --gate capture --json > $HOME/capture-gate.json 2>&1
echo "### capture gate: $(grep -o '"ready": *[a-z]*' $HOME/capture-gate.json | head -1)"
echo "### GOLDEN PREP DONE $(date -u) — shut down now, do NOT reboot"
