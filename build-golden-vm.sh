#!/bin/bash
# v3 golden decoder VM build driver — runs ON B3, logs to ~/appliance/v3/build.log
# Same pipeline as v2 (provision.sh clones CURRENT HamSCI main at build time),
# ssh port 5557 to avoid any stale v2 rig.
set -u
say(){ echo "[driver $(date '+%T')] $*"; }
die(){ say "FATAL: $*"; exit 1; }

# RIG_ROOT is the parent that holds v3 plus its build-rig siblings (build/,
# sigmond-ref/, vmbuild/). Resolved explicitly rather than via "../sibling"
# from inside v3 -- the kernel resolves ".." PHYSICALLY, so a v3 that is a
# symlink into a different physical location (it was, briefly, when the rig
# moved off B3's root disk) makes every "../X" silently point at a
# nonexistent sibling of the physical target while bash's own $PWD still
# shows the pre-move path. Same pattern as build-usb-v3.sh.
RIG_ROOT="${APPLIANCE_RIG_ROOT:-$HOME/appliance}"
[ -d "$RIG_ROOT" ] || die "rig root missing: $RIG_ROOT (check APPLIANCE_RIG_ROOT)"
cd "$RIG_ROOT/v3" || die "rig v3 checkout missing: $RIG_ROOT/v3 (check APPLIANCE_RIG_ROOT)"
LOG="$PWD/build.log"
exec > "$LOG" 2>&1

BUILD_DIR="${APPLIANCE_BUILD_DIR:-$RIG_ROOT/build}"
VMBUILD_DIR="${APPLIANCE_VMBUILD_DIR:-$RIG_ROOT/vmbuild}"
[ -d "$BUILD_DIR" ] || die "build dir missing: $BUILD_DIR (check APPLIANCE_BUILD_DIR)"
[ -d "$VMBUILD_DIR" ] || die "vmbuild dir missing: $VMBUILD_DIR (check APPLIANCE_VMBUILD_DIR)"
KEY="$BUILD_DIR/applkey"
SSH="ssh -i $KEY -p 5557 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 build@127.0.0.1"
SCP="scp -i $KEY -P 5557 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

say "creating fresh build disk from debian-13 base"
sudo pkill -f "name goldenv3" 2>/dev/null; sleep 2
[ -f "$VMBUILD_DIR/debian-13-genericcloud-amd64.qcow2" ] \
    || die "base qcow2 missing: $VMBUILD_DIR/debian-13-genericcloud-amd64.qcow2 (check APPLIANCE_VMBUILD_DIR)"
cp "$VMBUILD_DIR/debian-13-genericcloud-amd64.qcow2" golden-v3.qcow2
qemu-img resize golden-v3.qcow2 20G

# Build-VM memory.  8G is what the build wants; a rig with less must get less
# or qemu refuses to start and the whole ladder dies at step one.  The rig on
# sigmond-devbox has 7G total, and had carried a hand-edit to 4096 since at
# least 2026-09-16 -- an uncommitted local diff that silently forked the rig
# from the repo and would have been clobbered by the next `git pull`.  Size it
# from what the machine actually has instead, leaving 2G for the host, and let
# an operator override outright.
if [ -z "${APPLIANCE_BUILD_MEM:-}" ]; then
    _memtotal_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    APPLIANCE_BUILD_MEM=8192
    if [ -n "$_memtotal_mb" ] && [ "$_memtotal_mb" -lt 10240 ]; then
        APPLIANCE_BUILD_MEM=$(( (_memtotal_mb - 2048) / 1024 * 1024 ))
        [ "$APPLIANCE_BUILD_MEM" -lt 3072 ] \
            && die "only ${_memtotal_mb}M RAM on this rig; need ~5G to build"
    fi
fi
say "build VM memory: ${APPLIANCE_BUILD_MEM}M (override with APPLIANCE_BUILD_MEM)"

say "booting build VM (headless, ssh :5557)"
[ -f "$VMBUILD_DIR/seed.iso" ] || die "seed iso missing: $VMBUILD_DIR/seed.iso (check APPLIANCE_VMBUILD_DIR)"
sudo qemu-system-x86_64 -name goldenv3 -enable-kvm -m "$APPLIANCE_BUILD_MEM" -smp 4 -cpu host \
  -drive file=golden-v3.qcow2,if=virtio -drive file="$VMBUILD_DIR/seed.iso",media=cdrom \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5557-:22 -device virtio-net,netdev=n0 \
  -display none -daemonize

say "waiting for ssh"
for i in $(seq 1 60); do $SSH true 2>/dev/null && break; sleep 5; done
$SSH true || { say "FATAL: VM ssh never came up"; exit 1; }
say "VM up: $($SSH hostname 2>/dev/null)"

# ⛔ The decoder VM's ssh key is not optional.  provision-components.sh
# installs it only `if [ -f "$HOME/rob.pub" ]`, and on 2026-09-21 that file
# was absent on the rig, so the golden VM shipped with NO key-based access to
# the decoder VM.  It surfaced only when the guest agent went down on AI6VN
# and there was no remaining way in.  Refuse to build blind: the operator can
# still opt out explicitly.
#
# TWO paths were in play and they disagreed: the gate tested $HOME/rob.pub
# while the scp below read ./rob.pub relative to the rig checkout, so staging
# the key in the place the FATAL message named still failed at the copy.
# Resolve it ONCE here, checkout first (that copy travels with the rig and is
# what a fresh clone should carry), and use the resolved path everywhere.
OPKEY=""
for c in "$PWD/rob.pub" "$HOME/rob.pub"; do
    [ -f "$c" ] && { OPKEY="$c"; break; }
done
if [ -n "$OPKEY" ] && ! ssh-keygen -lf "$OPKEY" >/dev/null 2>&1; then
    # A truncated or mangled file installs silently and locks you out exactly
    # as thoroughly as no file at all.  Treat it as absent.
    say "WARNING: $OPKEY is not a readable ssh public key — ignoring it"
    OPKEY=""
fi
if [ -z "$OPKEY" ]; then
    say "FATAL: no operator public key found — the decoder VM would be built"
    say "  with NO authorized ssh key, leaving 'qm terminal 100' as the only"
    say "  way in when the guest agent is unavailable."
    say "  Looked for: $PWD/rob.pub  then  $HOME/rob.pub"
    say "  Put the operator public key at either, or set VMKEYLESS_OK=1."
    [ "${VMKEYLESS_OK:-0}" = 1 ] || die "refusing to build a keyless decoder VM"
    say "  VMKEYLESS_OK=1 — continuing WITHOUT a VM ssh key"
else
    say "operator key: $OPKEY — $(ssh-keygen -lf "$OPKEY" | awk '{print $1" "$2" "$4}')"
    say "  (an authorized_keys file may hold several; all of them are installed)"
fi
$SCP provision.sh provision-components.sh build@127.0.0.1:
[ -n "$OPKEY" ] && $SCP "$OPKEY" build@127.0.0.1:rob.pub
$SCP wisdomf-ryzen5825u build@127.0.0.1:wisdomf
# radiod's own channel-filter plans — a DIFFERENT file from wisdomf, which
# is planned non-threaded and which radiod's threaded plans never match.
# Without this, radiod silently runs FFTW_ESTIMATE plans (see
# provision-components.sh).
$SCP wisdom-radiod-plans-ryzen5825u build@127.0.0.1:wisdom-radiod-plans
say "stage 1: bootstrap (clone HamSCI/sigmond + install.sh)"
$SSH "chmod +x provision*.sh && setsid ./provision.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 120); do $SSH "grep -q 'BOOTSTRAP DONE' provision.log" 2>/dev/null && break; sleep 15; done
$SSH "grep -q 'BOOTSTRAP DONE' provision.log" || { say "FATAL: stage1 timeout"; $SSH "tail -20 provision.log"; exit 1; }
say "stage 1 done: $($SSH "grep '###' provision.log | tail -3")"

say "stage 1.5: swap cloud kernel -> generic (cloud kernel has NO USB stack; decoder VM needs RX888 USB passthrough — VM101 lesson 2026-07-25)"
$SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-amd64 >/dev/null"
CLOUDPKGS=$($SSH "dpkg -l | awk '/^ii  linux-image.*cloud/{print \$2}' | tr '\n' ' '")
say "cloud kernel packages: $CLOUDPKGS"
if [ -n "${CLOUDPKGS// }" ]; then
    $SSH "for p in $CLOUDPKGS; do echo \"\$p \$p/prompt-remove-running-kernel boolean false\" | sudo debconf-set-selections; done"
    $SSH "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $CLOUDPKGS >/dev/null && sudo update-grub >/dev/null 2>&1"
fi
say "rebooting build VM onto generic kernel"
$SSH "sudo reboot" 2>/dev/null; sleep 10
for i in $(seq 1 36); do $SSH true 2>/dev/null && break; sleep 5; done
KVER=$($SSH "uname -r" 2>/dev/null)
say "kernel after swap: $KVER"
case "$KVER" in *cloud*|"") say "FATAL: still on cloud kernel (or VM dead) — kernel swap failed"; exit 1;; esac
$SSH "dpkg -l | grep -q 'linux-image.*cloud'" && { say "FATAL: cloud kernel package still installed"; exit 1; }
$SSH "ls /lib/modules/\$(uname -r)/kernel/drivers/usb/host/ | grep -q xhci" || { say "FATAL: no xhci modules on new kernel"; exit 1; }
say "generic kernel active, USB (xhci) modules present"

say "stage 2+3: components + capture-prep (long — ka9q compile)"
$SSH "setsid ./provision-components.sh </dev/null >/dev/null 2>&1 &"
# Poll for the done marker -- but watch for '### FATAL' too.  provision-components.sh
# redirects its own output into provision.log inside the VM, so nothing it prints
# ever reaches this log; the driver used to learn about a failure only when this
# loop ran out, 240 * 30 s = TWO HOURS later.  On the v3.38 build (2026-09-11) the
# topology/profile guard rejected the template one second into the stage, over
# station-web, and the rig then sat waiting until the timeout with build.log frozen
# on "stage 2+3" and a healthy-looking qemu still running -- indistinguishable from
# a long ka9q compile.  A decided failure should cost seconds, so break on it.
STAGE23=timeout
for i in $(seq 1 240); do
    $SSH "grep -q 'GOLDEN PREP DONE' provision.log" 2>/dev/null && { STAGE23=done; break; }
    $SSH "grep -q '^### FATAL' provision.log"        2>/dev/null && { STAGE23=fatal; break; }
    sleep 30
done
if [ "$STAGE23" != done ]; then
    [ "$STAGE23" = fatal ] \
        && say "FATAL: stage2/3 refused the template — provision-components.sh reported:" \
        || say "FATAL: stage2/3 timeout after 2 h with no done marker and no FATAL"
    $SSH "grep -n '^### FATAL' -A 6 provision.log; echo '--- tail ---'; tail -30 provision.log"
    exit 1
fi
say "stage 2+3 done"
$SSH "grep '###' provision.log | tail -8"
$SSH "cat capture-gate.json 2>/dev/null | head -5"
# a not-ready gate means the template is missing components/artefacts — refuse to ship
if ! $SSH "grep -q '\"ready\": true' capture-gate.json"; then
    say "FATAL: capture gate NOT ready — template unusable; provision.log is inside golden-v3.qcow2"
    exit 1
fi
say "capture gate READY"

say "recording repo revisions for the build manifest"
$SSH "for d in /opt/git/sigmond/*/; do printf '%s %s\n' \"\$(basename \$d)\" \"\$(git -C \$d rev-parse --short HEAD 2>/dev/null)\"; done" | tee golden-v3-revs.txt

# ── is every component actually at the LATEST commit? ───────────────────────
# The whole point of cloning at build time is that the template carries the
# top of main.  Nothing ever CHECKED that.  A clone can land behind for dull
# reasons -- a push that lost the race with the build, a component whose
# default branch is not what we assume, a checkout smd reused instead of
# refetching -- and the result is an image that looks current, ships, and is
# quietly a few commits old across 25 repos with no signal anywhere.
#
# rob, 2026-09-22: "i'm not worried about recreating an image, just be sure
# that an image is created with the latest commits."  So: no pinning, no
# reproducibility machinery -- just ask each remote what its head is, while
# we are still inside the build VM and the network is up, and refuse to bless
# a template that is behind.
say "checking every component against its remote's latest commit"
$SSH 'for d in /opt/git/sigmond/*/; do
        n=$(basename "$d")
        loc=$(git -C "$d" rev-parse HEAD 2>/dev/null) || { printf "%s - - NOGIT\n" "$n"; continue; }
        br=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null)
        if [ -z "$br" ]; then printf "%s %.7s - DETACHED\n" "$n" "$loc"; continue; fi
        rem=$(git -C "$d" ls-remote origin "refs/heads/$br" 2>/dev/null | awk "{print \$1; exit}")
        if [ -z "$rem" ]; then printf "%s %.7s - UNREACHABLE\n" "$n" "$loc"; continue; fi
        if [ "$loc" = "$rem" ]; then printf "%s %.7s %.7s CURRENT\n" "$n" "$loc" "$rem"
        else printf "%s %.7s %.7s BEHIND\n" "$n" "$loc" "$rem"; fi
      done' > golden-v3-freshness.txt 2>/dev/null
if [ -s golden-v3-freshness.txt ]; then
    awk '{printf "  %-18s %-9s %-9s %s\n", $1, $2, $3, $4}' golden-v3-freshness.txt
    _behind=$(awk '$4=="BEHIND"{print $1}' golden-v3-freshness.txt)
    _blind=$(awk '$4=="UNREACHABLE"||$4=="DETACHED"||$4=="NOGIT"{print $1}' golden-v3-freshness.txt)
    [ -n "$_blind" ] && say "NOTE: not verifiable: $(echo $_blind | tr '\n' ' ')"
    if [ -n "$_behind" ]; then
        say "FATAL: these components are NOT at their remote's latest commit:"
        for c in $_behind; do say "         $c"; done
        say "  The template would ship stale code.  Usually this means a push"
        say "  landed after the clone -- rerun ./build-golden-vm.sh."
        say "  Deliberate old-code build: GOLDEN_ALLOW_BEHIND=1"
        [ "${GOLDEN_ALLOW_BEHIND:-0}" = 1 ] || exit 1
        say "  GOLDEN_ALLOW_BEHIND=1 — continuing with stale components"
    else
        say "all verifiable components are at their remote's latest commit"
    fi
else
    say "WARNING: freshness check produced nothing — components NOT verified"
fi

# The manifest that build-usb-v3.sh ships with the image and that a Release
# attaches — this is the only point in the pipeline where components are
# installed AND still reachable over ssh (smd version reports "no component
# checkouts found" on B3 itself; it only works run inside the appliance).
# Best-effort here, not fatal: a missing/malformed manifest-raw.txt must not
# silently produce an unmanifested image, but it also shouldn't waste a
# completed, otherwise-good template. build-usb-v3.sh is the hard gate — it
# refuses to ship without this file.
say "capturing component pin manifest (smd version) from the template"
$SSH 'smd version' > manifest-raw.txt 2>/dev/null
NCOMP=$(grep -c '^    [A-Za-z]' manifest-raw.txt 2>/dev/null || true); NCOMP=${NCOMP:-0}
# Gate on the row COUNT, not just the "components (live):" header string.
# A capture that connects and is cut off right after the header -- an ssh
# drop, the remote smd process killed mid-write, the VM beginning to shut
# down concurrently -- still contains that header and would pass a bare
# grep -q, shipping a manifest that LIES about having zero component pins.
# 10 is a plausible floor for THIS pipeline specifically: provision-components.sh
# (run earlier in this script's stage 2+3) hardcodes the full dasi2 topology (radiod ka9q-web
# igmp-querier gpsdo-monitor hf-timestd wspr-recorder psk-recorder
# mag-recorder meteor-scatter, ~20+ repos total, 22 on B4 as of 2026-08-15)
# with no profile parameter -- this script never builds smd's leaner
# catalog.toml profiles (e.g. "base": 1 client + 2 infra, "client": 3
# clients with no local radiod), which would legitimately report well
# under 10. If this pipeline ever grows a profile argument, this constant
# must move with it, or a legitimate lean build will trip the gate.
# 10 itself is chosen well under today's dasi2 count so a handful of
# components coming and going over time won't false-positive, but far
# above anything a truncated capture produces.
if grep -q 'components (live):' manifest-raw.txt 2>/dev/null && [ "$NCOMP" -ge 10 ]; then
    say "manifest captured: $NCOMP component lines"
else
    say "WARNING: manifest capture FAILED or truncated ($NCOMP component lines) — image will be unblessable (manifest-raw.txt missing or malformed); build-usb-v3.sh will refuse to ship without it"
    rm -f manifest-raw.txt
fi

say "shutting down VM (halt, not reboot — no machine-id now)"
$SSH "sudo shutdown -h now" 2>/dev/null
for i in $(seq 1 24); do pgrep -f "name goldenv3" >/dev/null || break; sleep 5; done
pgrep -f "name goldenv3" >/dev/null && { say "force stop"; sudo pkill -f "name goldenv3"; sleep 3; }

say "compacting template"
qemu-img convert -O qcow2 -c golden-v3.qcow2 sigmond-decoder-template-v3.qcow2
ls -la sigmond-decoder-template-v3.qcow2
say "GOLDEN VM BUILD COMPLETE"
