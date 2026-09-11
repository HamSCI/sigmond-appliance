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

# meteor-scatter is a dasi2 CORE client as of sigmond a8bc72b (2026-08-08) --
# it was `optional` until B4's v3.21 install showed the service running while
# neither topology.toml nor the profile that provisions it declared it.
# Declared here so the image's topology matches the profile.
[component.meteor-scatter]
enabled = true

# gmag-webui is a dasi2 CORE client as of sigmond 9833c25 (2026-08-22): the
# HamSCI magnetometer real-time dashboard (HamSCI/gmag_webui), served by a
# pinned Deno from our own unit, reading mag-usb's WebSocket feed. The DASI2
# PI wants it on every deployment VM. Declared here so the image's topology
# matches the profile (same reason as meteor-scatter above).
[component.gmag-webui]
enabled = true

# hamsci-physics is a dasi2 CORE client as of sigmond e08d82c (2026-09-03): the
# profile description promises GRAPE and this is what produces it, while
# hf-timestd's installer enables grape-daily and hamsci-physics-reanalysis
# against its venv unconditionally.  Declared here so the image's topology
# matches the profile (same reason as meteor-scatter and gmag-webui above --
# the THIRD time this list has drifted from the catalog, which is why the
# check below now exists).
[component.hamsci-physics]
enabled = true

# station-web is a dasi2 CORE client as of sigmond 2026-09-06 (the hf-timestd
# split, Phase 5): it replaces the web UI hf-timestd used to carry as
# timestd-web-api.service, so a station without it serves no pages at all.
# Declared here so the image's topology matches the profile -- the FOURTH time
# this list has drifted, and the first one the guard below actually caught
# before a station paid for it.
[component.station-web]
enabled = true
EOF
echo "### topology enabled: dasi2 set (radiod ka9q-web igmp-querier gpsdo-monitor hf-timestd wspr-recorder psk-recorder mag-recorder gmag-webui meteor-scatter hamsci-physics station-web)"

# ⛔ The topology above restates the dasi2 profile BY HAND, and it has drifted
# from the catalog four times: meteor-scatter (2026-08-08), gmag-webui
# (2026-08-22), hamsci-physics (2026-09-03), station-web (2026-09-06, caught by
# this guard on the v3.38 build).  Each time the mechanism was the
# same and it was silent -- `smd install` installs what TOPOLOGY enables, not
# what the PROFILE lists, so a client added to the profile never reached the
# template, `smd install` exited 0, and the gap surfaced later: on the capture
# gate if we were lucky, on a live station if we were not.  AC0G-ND ran for
# days with a hamsci-physics checkout, no venv and no GRAPE.
#
# So assert the two agree, and stop the build here if they do not.  The catalog
# is the source of truth; this reads it through sigmond's own loader rather
# than hand-parsing a second copy of it.  A missing component now names itself
# in one line, instead of appearing as five capture-gate failures six minutes
# later (or as a warning nobody reads).
echo "### verifying the template topology covers the dasi2 profile"
MISSING=$(python3 - <<'PYGUARD'
import sys, tomllib, warnings
from pathlib import Path

# Resolving the `radiod` topology key through the catalog is deliberate here,
# so its deprecation notice is noise, and it would otherwise land in
# provision.log looking like a build problem.
warnings.simplefilter('ignore', DeprecationWarning)

smd = Path('/usr/local/bin/smd').resolve()
for cand in (smd.parent.parent / 'lib', Path('/opt/sigmond/lib'),
             Path('/usr/local/lib/sigmond')):
    if (cand / 'sigmond' / '__init__.py').exists():
        sys.path.insert(0, str(cand))
        break
else:
    print('GUARD-BROKEN: cannot locate sigmond lib to read the catalog')
    raise SystemExit(0)

from sigmond.catalog import load_catalog, load_profiles, resolve_name

catalog = load_catalog()
profile = load_profiles()['dasi2']
wanted = list(profile.clients) + list(profile.local_radiod_infra)

with open('/etc/sigmond/topology.toml', 'rb') as fh:
    topo = tomllib.load(fh)
# Resolve every topology key through the catalog, so `radiod` and `ka9q-radio`
# name the same component here as they do everywhere else.
enabled = set()
for name, block in (topo.get('component') or {}).items():
    if isinstance(block, dict) and block.get('enabled'):
        enabled.add(name)
        try:
            enabled.add(resolve_name(name, catalog))
        except Exception:
            pass

print(' '.join(c for c in wanted if c not in enabled))
PYGUARD
) || {
    # ⛔ FAIL CLOSED.  A guard that dies (missing import, unreadable topology,
    # a catalog that will not parse) leaves MISSING empty, which reads exactly
    # like "nothing missing".  This fleet has shipped that mistake before -- a
    # dependency check that failed open and passed an image with no lsof.  A
    # check whose own result cannot be trusted must stop the build.
    echo "### FATAL: the topology/profile guard itself failed to run"
    echo "###   refusing to build blind — an empty result from a broken check"
    echo "###   is indistinguishable from a passing one"
    exit 1
}
case "$MISSING" in
    GUARD-BROKEN*) echo "### FATAL: $MISSING"; exit 1 ;;
esac
if [ -n "${MISSING// }" ]; then
    echo "### FATAL: the dasi2 profile lists components this template topology does not enable:"
    echo "###   $MISSING"
    echo '###   smd install installs what topology enables, so the image would ship WITHOUT them.'
    echo '###   fix: add [component.<name>] enabled = true to the heredoc above in provision-components.sh'
    exit 1
fi
echo "### topology covers the dasi2 profile ✓"
echo "### smd install  (self-elevates; compiles ka9q-radio — long) ..."
smd install --yes
RC=$?
echo "### smd install exit=$RC"
# The client installers run as root and leave egg-info / build products
# root-owned inside checkouts that belong to the client users.  `smd doctor`
# then flags every one of them on the first boot of every image -- 12 findings
# on v3.37 (AI6VN 2026-09-05), all "repairable with smd doctor --fix".  Repair
# in the template so the image ships clean; the real fix belongs in sigmond's
# installer (run build steps as the checkout owner) and this line becomes a
# no-op the day it lands.
echo "### smd doctor --fix (ownership left behind by the installers)"
sudo smd doctor --fix 2>&1 | tail -20 || true
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
fi

# radiod's OWN channel-filter plans are a separate file and a separate
# problem.  /etc/fftw/wisdomf above is planned non-threaded, while radiod
# calls fftwf_plan_with_nthreads() and looks for
# /var/lib/ka9q-radio/wisdom-fftw-<ver>-threaded — so its plans missed
# system wisdom entirely.  On a miss radiod does NOT plan slowly, it
# silently falls back to FFTW_ESTIMATE (filter.c:105-108): suboptimal
# forever and invisible in startup time.  AC0G-B4 2026-08-15 was running
# estimate plans for seven transforms (cif2400 cif300 cif512 cif600
# cob2400 cob512 cof512) on an image that "shipped the wisdom".
# This file is the one that took B4's miss count to zero, verified via
# /var/lib/ka9q-radio/fft.log — which radiod writes ONLY on a miss, and
# is therefore the check to run on any new host:
#     wc -l /var/lib/ka9q-radio/fft.log   # 0 == fully planned
# Same silicon/FFTW-version/thread-count caveat as wisdomf; on a foreign
# CPU FFTW ignores it and radiod falls back as before.
if [ -f "$HOME/wisdom-radiod-plans" ]; then
    sudo mkdir -p /var/lib/ka9q-radio
    sudo cp "$HOME/wisdom-radiod-plans" \
        /var/lib/ka9q-radio/wisdom-fftw-3.3.10-sse2-avx-threaded
    sudo chmod 644 /var/lib/ka9q-radio/wisdom-fftw-3.3.10-sse2-avx-threaded
    echo "### radiod-plan wisdom baked: $(wc -c < /var/lib/ka9q-radio/wisdom-fftw-3.3.10-sse2-avx-threaded) bytes"
else
    echo "### WARNING: no wisdom file supplied — planner will run on first boot"
fi
echo "### GOLDEN PREP DONE $(date -u) — shut down now, do NOT reboot"
