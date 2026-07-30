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

[component.igmp-querier]
enabled = true

[component.gpsdo-monitor]
enabled = true

[component.hf-timestd]
enabled = true

[component.wspr-recorder]
enabled = true

[component.psk-recorder]
enabled = true

[component.mag-recorder]
enabled = true
EOF
echo "### topology enabled: dasi2 set (radiod ka9q-web igmp-querier gpsdo-monitor hf-timestd wspr-recorder psk-recorder mag-recorder)"
echo "### smd install  (self-elevates; compiles ka9q-radio — long) ..."
smd install --yes
RC=$?
echo "### smd install exit=$RC"
echo "### --- smd list ---"
smd component list 2>&1 | head -30 || true
echo "### COMPONENTS DONE (rc=$RC) $(date -u)"

echo "### operator account: hamsci (fleet convention, NOPASSWD sudo, rob's key)"
sudo useradd -m -s /bin/bash hamsci 2>/dev/null || true
echo 'hamsci:hamsci-sigmond' | sudo chpasswd   # ONE password everywhere (rob 2026-07-30)
echo 'hamsci ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/hamsci >/dev/null
sudo chmod 440 /etc/sudoers.d/hamsci
sudo mkdir -p /home/hamsci/.ssh
if [ -f "$HOME/rob.pub" ]; then
    sudo cp "$HOME/rob.pub" /home/hamsci/.ssh/authorized_keys
    sudo chown -R hamsci:hamsci /home/hamsci/.ssh
    sudo chmod 700 /home/hamsci/.ssh; sudo chmod 600 /home/hamsci/.ssh/authorized_keys
    echo "### hamsci ssh key installed"
fi

echo "### stage 3: capture-prep (scrub identity/secrets/data for golden image)"
sudo mkdir -p /etc/systemd/network
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' | sudo tee /etc/systemd/network/99-dhcp-all.network >/dev/null
sudo systemctl enable systemd-networkd >/dev/null 2>&1
echo "### catch-all DHCP network config baked (en*)"
sudo cloud-init clean --logs 2>/dev/null; echo "### cloud-init cleaned"
smd admin capture-prep --yes
echo "### capture-prep exit=$?"
smd admin readiness --gate capture --json > $HOME/capture-gate.json 2>&1
echo "### capture gate: $(grep -o '"ready": *[a-z]*' $HOME/capture-gate.json | head -1)"

echo "### FFTW wisdom bake — AFTER capture-prep, which deliberately scrubs it"
# capture-prep deletes /etc/fftw/wisdomf ("per-CPU — a clone must
# regenerate"), which is exactly why v3.0/v3.1 golden shipped without
# wisdom and every deployed box burned hours re-planning at 1.4 GHz
# (rob 2026-07-27: ship the wisdom).  The appliance fleet is uniform
# Ryzen 5825U silicon — the build VM runs -cpu host on B3 (same CPU),
# and this file is live-proven on B3's VM 120 and B4's production VM.
# On foreign CPUs FFTW ignores non-matching wisdom and falls back to
# runtime planning; sigmond-wisdom.service (condition: file absent)
# stays baked as the generator of last resort — delete the file on
# foreign hardware to re-arm it.
if [ -f "$HOME/wisdomf" ]; then
    sudo mkdir -p /etc/fftw
    sudo cp "$HOME/wisdomf" /etc/fftw/wisdomf
    sudo chmod 644 /etc/fftw/wisdomf
    echo "### wisdom baked post-prep: $(wc -c < /etc/fftw/wisdomf) bytes (Ryzen 5825U / fftw 3.3.10)"
else
    echo "### WARNING: no wisdom file supplied — planner will run on first boot"
fi
echo "### GOLDEN PREP DONE $(date -u) — shut down now, do NOT reboot"
