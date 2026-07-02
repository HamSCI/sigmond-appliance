#!/bin/bash
# Complete the dasi2 profile in the build VM, re-scrub, re-gate.
exec >> "$HOME/provision.log" 2>&1
echo ""
echo "### $(date -u) PROFILE COMPLETION: enabling full dasi2 set"
sudo tee /etc/sigmond/topology.toml >/dev/null <<'TOPO'
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
TOPO
echo "### topology: full dasi2 (4 clients + 3 infra + radiod)"
smd install --yes
echo "### smd install exit=$?"
sudo cloud-init clean --logs 2>/dev/null
smd admin capture-prep --yes
echo "### capture-prep exit=$?"
smd admin readiness --gate capture --json > "$HOME/capture-gate.json" 2>&1
echo "### capture gate: $(grep -o '"ready": *[a-z]*' "$HOME/capture-gate.json" | head -1)"
echo "### GOLDEN PREP V2 DONE $(date -u)"
