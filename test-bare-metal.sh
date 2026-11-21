#!/bin/bash
# test-bare-metal.sh -- the rig's bare-metal install test.  Runs ON the rig.
#
#   test-bare-metal.sh <version> [--commit SHA] [--dry-run]
#
# The image test proves the Proxmox path.  This test proves the other one:
# an operator's own Debian machine, set up from sigmond's
# docs/install-bare-metal.md.  It boots a fresh Debian 13 VM, types the doc's
# own commands into it at the sigmond commit under test, runs the bring-up
# the doc names, and judges `smd check`.  sigmond's bless gate 10 reads the
# record it writes.
#
# What it runs, and where each piece comes from:
#   - the commit: --commit, else the golden VM's sigmond commit (C4,
#     $RIG_DIR/golden-v3-sigmond-commit.txt).  It must sit on sigmond's
#     origin, since the VM clones from there.
#   - the version: release/components.toml at that commit must name
#     <version>.
#   - the commands: docs/install-bare-metal.md at sigmond origin/main, the doc
#     the bless publishes.  Its `git checkout <version>` line must name
#     <version>.  `python3 -m sigmond.bare_metal_doc script` turns it into two
#     parts: install (the checkout line rewritten to the commit) and bring-up
#     (whatever bring-up the doc names, with a throwaway identity and
#     --non-interactive).  Nothing here names a profile.
#   - the verdict: `smd admin release-list --check` and `smd check --json` in
#     the VM, the second judged by `python3 -m sigmond.bare_metal_doc judge`
#     ("waits on dormant radiod" is a pass; any FAIL is not).
#
# The VM, and why it differs from a stock cloud image in two ways:
#   - it carries a USB controller (-device qemu-xhci).  smd check tells a
#     dormant radiod from a broken one by asking lsusb whether an SDR sits on
#     the bus, and it reads an EMPTY listing as "SDR unknown", which keeps the
#     radiod consumers FAILing.  With a controller lsusb lists a root hub, and
#     the absent RX888 reads "no SDR".
#   - it runs Debian's generic kernel.  The genericcloud kernel has no USB
#     stack at all, so the controller would show nothing.  The test swaps
#     kernels and reboots before the doc runs, as build-golden-vm.sh stage 1.5
#     does, and stops (no record) if no root hub appears.  A real machine
#     runs the generic kernel already, so this makes the VM more like one.
#   - name baremetal, disk bare-metal-test.qcow2 (40G) in $RIG_DIR, ssh on
#     127.0.0.1:5558, the same seed.iso and build user as the golden VM.  It
#     never touches the goldenv3 VM, its disk or its port 5557.  It stops by
#     its own pidfile, never `pkill -f`.
#   - RAC is pinned to 127.0.0.1 before the doc runs (rac-endpoint.env, as
#     test-nested-v3.sh does), so bring-up's `sigmond-rac activate` never
#     registers this VM with the fleet gateway.
#
# Exit 0 only on result: PASS.  A run that reaches the doc's commands writes
# one record, $RIG_DIR/bare-metal/<version>-<stamp>.record (contract C2,
# bare-metal-lib.sh); a doc command that fails writes result: FAIL with
# smd_check_exit: -1.  Bring-up's exit 3 with its PARTIAL-for-no-SDR line
# counts as success (the VM has no RX888), and the checks then run as usual.  A rig fault before the doc runs (VM never boots, no
# ssh, no USB bus) writes no record: it says nothing about the release.
# Neither does an install whose sigmond checkout ends at a commit other than
# the one under test (/tmp/bm-sigmond-head in the VM).
# The log: $RIG_DIR/bare-metal/<version>-<stamp>.log.  Expect it to take as
# long as a bring-up, up to an hour.
#
# Env: APPLIANCE_RIG_ROOT (default $HOME/appliance), SIGMOND_REPO (default
# $RIG_ROOT/repos/sigmond), APPLIANCE_VMBUILD_DIR (default $RIG_ROOT/vmbuild:
# debian-13-genericcloud-amd64.qcow2, seed.iso), APPLIANCE_BUILD_DIR (default
# $RIG_ROOT/build: applkey), RIG_DIR (default $RIG_ROOT/v3),
# APPLIANCE_BUILD_MEM (MiB; default sized as build-golden-vm.sh sizes it).
set -u
say(){ echo "[bare-metal $(date '+%T')] $*"; }
die(){ say "FATAL: $*"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

usage(){ echo "usage: $0 <version> [--commit SHA] [--dry-run]" >&2; exit 2; }
VERSION=""; COMMIT=""; DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --commit) [ $# -ge 2 ] || usage; COMMIT="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) [ -z "$VERSION" ] || usage; VERSION="$1"; shift ;;
    esac
done
[[ "$VERSION" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage

RIG_ROOT="${APPLIANCE_RIG_ROOT:-$HOME/appliance}"
SIGMOND_REPO="${SIGMOND_REPO:-$RIG_ROOT/repos/sigmond}"
VMBUILD_DIR="${APPLIANCE_VMBUILD_DIR:-$RIG_ROOT/vmbuild}"
BUILD_DIR="${APPLIANCE_BUILD_DIR:-$RIG_ROOT/build}"
RIG_DIR="${RIG_DIR:-$RIG_ROOT/v3}"
BM_DIR="$RIG_DIR/bare-metal"
# shellcheck disable=SC1091
. "$HERE/release-home-lib.sh" || die "cannot source $HERE/release-home-lib.sh"
# shellcheck disable=SC1091
. "$HERE/bare-metal-lib.sh"   || die "cannot source $HERE/bare-metal-lib.sh"
[ -d "$SIGMOND_REPO/.git" ] || die "no sigmond checkout at $SIGMOND_REPO (check SIGMOND_REPO)"
[ -d "$RIG_DIR" ] || die "rig dir missing: $RIG_DIR (check RIG_DIR)"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [ "$DRY" = 0 ]; then
    mkdir -p "$BM_DIR" || die "cannot create $BM_DIR"
    LOG="$BM_DIR/$VERSION-$STAMP.log"
    exec > >(tee -a "$LOG") 2>&1
    say "log: $LOG"
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ---- what to test: the commit, its list, and the doc's commands -----------
git -C "$SIGMOND_REPO" fetch -q origin \
    || die "git fetch origin failed in $SIGMOND_REPO (the doc and the commit come from origin)"
if [ -z "$COMMIT" ]; then
    COMMIT="$(rh_sigmond_commit "$RIG_DIR")" || die "no --commit, and no golden VM commit (C4) to test"
fi
FULL="$(git -C "$SIGMOND_REPO" rev-parse -q --verify "$COMMIT^{commit}" 2>/dev/null)" \
    || die "sigmond has no commit '$COMMIT'"
COMMIT="$FULL"
[ -n "$(git -C "$SIGMOND_REPO" branch -r --contains "$COMMIT" 2>/dev/null)" ] \
    || die "sigmond $COMMIT is on no origin branch; the VM clones from origin and could not check it out -- push it first"
LISTV="$(rh_version "$SIGMOND_REPO" "$COMMIT")" \
    || die "cannot read the release list at sigmond ${COMMIT:0:12}"
[ "$LISTV" = "$VERSION" ] \
    || die "release/components.toml at sigmond ${COMMIT:0:12} names $LISTV, not $VERSION"

DOC="$WORK/install-bare-metal.md"
git -C "$SIGMOND_REPO" show "origin/main:docs/install-bare-metal.md" > "$DOC" 2>/dev/null \
    || die "docs/install-bare-metal.md is not readable at sigmond origin/main"
bmd(){ _rh_py "$SIGMOND_REPO" -m sigmond.bare_metal_doc "$@"; }
CO="$(bmd checkout-version --doc "$DOC" 2>&1)" \
    || die "docs/install-bare-metal.md at origin/main does not read as a test script: $CO (it needs one 'git checkout $VERSION' line in section 2)"
[ "$CO" = "$VERSION" ] \
    || die "docs/install-bare-metal.md at origin/main checks out '${CO:-no release}', not $VERSION: it needs the line 'git checkout $VERSION' in section 2"
DIGEST="$(bmd digest --doc "$DOC")" || die "cannot take the digest of the doc's commands"
bmd script --doc "$DOC" --commit "$COMMIT" --part install > "$WORK/bm-install.sh" \
    || die "cannot build the install part from the doc"
bmd script --doc "$DOC" --commit "$COMMIT" --part bringup > "$WORK/bm-bringup.sh" \
    || die "cannot build the bring-up part from the doc"
say "testing $VERSION at sigmond $COMMIT; doc commands ${DIGEST:0:12} (origin/main $(git -C "$SIGMOND_REPO" rev-parse --short origin/main))"

if [ "$DRY" = 1 ]; then
    echo "--- install part (one ssh session) ---"
    cat "$WORK/bm-install.sh"
    echo "--- bring-up part (a fresh ssh session) ---"
    cat "$WORK/bm-bringup.sh"
    echo "--- record ---"
    echo "would write $BM_DIR/$VERSION-<finish stamp>.record, e.g. $BM_DIR/$VERSION-$STAMP.record"
    exit 0
fi

# ---- the VM -----------------------------------------------------------------
BASE="$VMBUILD_DIR/debian-13-genericcloud-amd64.qcow2"
SEED="$VMBUILD_DIR/seed.iso"
KEY="$BUILD_DIR/applkey"
DISK="$RIG_DIR/bare-metal-test.qcow2"
PIDF="$RIG_DIR/bare-metal-test.pid"
[ -f "$BASE" ] || die "base qcow2 missing: $BASE (check APPLIANCE_VMBUILD_DIR)"
[ -f "$SEED" ] || die "seed iso missing: $SEED (check APPLIANCE_VMBUILD_DIR)"
[ -f "$KEY" ]  || die "ssh key missing: $KEY (check APPLIANCE_BUILD_DIR)"
# ServerAliveInterval: a bring-up may run an hour in one session.
SSHOPT="-i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o ServerAliveInterval=60"
vm(){ ssh -n $SSHOPT -p 5558 build@127.0.0.1 "$1"; }
to_vm(){ scp $SSHOPT -P 5558 "$1" "build@127.0.0.1:$2"; }

# Stop the VM this test started, by its pidfile.  The pid must still be a
# qemu named baremetal: a stale pidfile may name a recycled pid.
stop_vm(){
    [ -s "$PIDF" ] || return 0
    local pid i
    pid="$(cat "$PIDF" 2>/dev/null)"
    if [[ "$pid" =~ ^[0-9]+$ ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- '-name baremetal'; then
        sudo kill "$pid" 2>/dev/null
        for i in $(seq 1 30); do sudo kill -0 "$pid" 2>/dev/null || break; sleep 1; done
        sudo kill -9 "$pid" 2>/dev/null
    fi
    sudo rm -f "$PIDF"
}
trap 'stop_vm; rm -rf "$WORK"' EXIT

stop_vm
if vm true 2>/dev/null; then
    die "something already answers ssh on 127.0.0.1:5558; this test will not share the port"
fi

if [ -z "${APPLIANCE_BUILD_MEM:-}" ]; then
    _memtotal_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    APPLIANCE_BUILD_MEM=8192
    if [ -n "$_memtotal_mb" ] && [ "$_memtotal_mb" -lt 10240 ]; then
        APPLIANCE_BUILD_MEM=$(( (_memtotal_mb - 2048) / 1024 * 1024 ))
        [ "$APPLIANCE_BUILD_MEM" -lt 3072 ] && die "only ${_memtotal_mb}M RAM on this rig"
    fi
fi

say "fresh disk from the debian-13 base, 40G"
cp "$BASE" "$DISK" || die "cannot copy $BASE to $DISK"
qemu-img resize "$DISK" 40G >/dev/null || die "qemu-img resize $DISK failed"
say "booting VM baremetal (${APPLIANCE_BUILD_MEM}M, ssh :5558, USB controller qemu-xhci)"
sudo qemu-system-x86_64 -name baremetal -enable-kvm -m "$APPLIANCE_BUILD_MEM" -smp 4 -cpu host \
  -drive file="$DISK",if=virtio -drive file="$SEED",media=cdrom \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:5558-:22 -device virtio-net,netdev=n0 \
  -device qemu-xhci,id=xhci \
  -display none -daemonize -pidfile "$PIDF" || die "qemu would not start"

wait_ssh(){ local i; for i in $(seq 1 "$1"); do vm true 2>/dev/null && return 0; sleep 5; done; vm true 2>/dev/null; }
wait_ssh 60 || die "the VM's ssh never came up (no record: a rig fault)"
say "VM up"

# Machine prep, not the doc: the generic kernel (see the header).
say "prep: swap the cloud kernel for the generic one (the cloud kernel has no USB stack)"
# A fresh cloud image ships with no package lists.
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null" \
    || die "prep: apt-get update failed"
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq linux-image-amd64 >/dev/null" \
    || die "prep: apt-get install linux-image-amd64 failed"
CLOUDPKGS="$(vm "dpkg -l | awk '/^ii  linux-image.*cloud/{print \$2}' | tr '\n' ' '")"
if [ -n "${CLOUDPKGS// }" ]; then
    vm "for p in $CLOUDPKGS; do echo \"\$p \$p/prompt-remove-running-kernel boolean false\" | sudo debconf-set-selections; done"
    vm "sudo DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $CLOUDPKGS >/dev/null && sudo update-grub >/dev/null 2>&1" \
        || die "prep: purging the cloud kernel failed"
fi
vm "sudo reboot" 2>/dev/null; sleep 10
wait_ssh 36 || die "the VM did not come back after the kernel swap"
KVER="$(vm "uname -r" 2>/dev/null)"
case "$KVER" in *cloud*|"") die "prep: still on the cloud kernel ('$KVER')";; esac
vm "dpkg -l | grep -q 'linux-image.*cloud'" && die "prep: a cloud kernel package is still installed"
HUBS="$(vm "ls -d /sys/bus/usb/devices/usb[0-9]* 2>/dev/null")"
grep -q 'usb[0-9]' <<< "$HUBS" \
    || die "prep: the VM shows no USB root hub on kernel $KVER; smd check would read the bus as unknown and every radiod consumer would FAIL (no record: a rig fault)"
say "prep: kernel $KVER, USB root hub(s): $(tr '\n' ' ' <<< "$HUBS")"

# ⛔ Pin RAC before the doc runs, exactly as test-nested-v3.sh pins it: bring-up
# activates remote access, and unpinned it would register this VM with the
# real gateway.  The same four variables go into each session's environment.
RACENV="SIGMOND_RAC_SERVER=127.0.0.1 SIGMOND_RAC_REGISTRAR=http://127.0.0.1:35737/register SIGMOND_RAC_TLS=off SIGMOND_RAC_FRPS_PORT=35735"
case "$(vm "sudo mkdir -p /etc/sigmond-appliance && printf '%s\n' $RACENV | sudo tee /etc/sigmond-appliance/rac-endpoint.env >/dev/null && grep -qx 'SIGMOND_RAC_SERVER=127.0.0.1' /etc/sigmond-appliance/rac-endpoint.env && echo PIN:OK" 2>&1)" in
    *PIN:OK*) say "RAC pinned to 127.0.0.1" ;;
    *) die "could not pin RAC in the VM (the pin did not read back)" ;;
esac

# ---- the doc's commands -------------------------------------------------------
to_vm "$WORK/bm-install.sh" /tmp/bm-install.sh || die "cannot copy the install part into the VM"
to_vm "$WORK/bm-bringup.sh" /tmp/bm-bringup.sh || die "cannot copy the bring-up part into the VM"

# run_part <name>: one ssh session, a login shell, no stdin.  255 is ssh's own
# failure, not the doc's.  The output also lands in $WORK/bm-<name>.out.
run_part(){
    local rc
    say "--- $1 part ---"
    vm "env $RACENV bash -l /tmp/bm-$1.sh </dev/null" | tee "$WORK/bm-$1.out"; rc=${PIPESTATUS[0]}
    say "--- $1 part exit $rc ---"
    [ "$rc" = 255 ] && die "ssh failed during the $1 part (no record: a rig fault)"
    # The VM has no RX888: bring-up defers the radio half and exits 3 PARTIAL.
    # That, and only that, is the doc's success (bm_bringup_partial_ok).
    if [ "$1" = bringup ] && bm_bringup_partial_ok "$rc" "$WORK/bm-$1.out"; then
        say "bring-up ended PARTIAL for want of an SDR (exit 3): the doc's success on a VM with no RX888"
        return 0
    fi
    return "$rc"
}
record(){   # record <list_rc> <check_exit> <judge_rc>: write C2, print it, exit
    local path res
    path="$(bm_record "$BM_DIR" "$VERSION" "$COMMIT" "$DIGEST" "$1" "$2" "$3")" \
        || die "could not write the record"
    say "record: $path"
    sed 's/^/    /' "$path"
    res="$(_bm_key "$path" result)"
    say "result: $res"
    [ "$res" = PASS ] && exit 0
    exit 1
}

STEP_FAIL=""
vm "rm -f /tmp/bm-sigmond-head" || true
run_part install || STEP_FAIL=install
# The install part's last line writes the commit the doc's checkout stands at
# (sigmond's bare_metal_doc adds it).  A record must never vouch for code that
# did not run: a checkout at any other commit is a rig fault, not a verdict.
if [ -z "$STEP_FAIL" ]; then
    GOT_HEAD="$(vm "cat /tmp/bm-sigmond-head" 2>/dev/null | tr -d '[:space:]')"
    [ "$GOT_HEAD" = "$COMMIT" ] \
        || die "the VM's sigmond checkout stands at '${GOT_HEAD:-nothing}', not $COMMIT (no record: a rig fault)"
    say "the VM's sigmond checkout stands at $COMMIT"
fi
[ -z "$STEP_FAIL" ] && { run_part bringup || STEP_FAIL=bringup; }
if [ -n "$STEP_FAIL" ]; then
    say "the doc's $STEP_FAIL commands failed; smd check below is for the log only"
    vm "bash -lc 'smd check'" || true
    record 1 -1 1
fi

# ---- the verdict ----------------------------------------------------------------
say "--- smd admin release-list --check ---"
vm "bash -lc 'smd admin release-list --check'"; LIST_RC=$?
[ "$LIST_RC" = 255 ] && die "ssh failed during release-list --check (no record)"
say "release-list --check exit $LIST_RC"

say "--- smd check --json ---"
vm "bash -lc 'smd check --json'" > "$WORK/check.json"; CHECK_RC=$?
[ "$CHECK_RC" = 255 ] && die "ssh failed during smd check (no record)"
cat "$WORK/check.json"
say "smd check exit $CHECK_RC"

say "--- judge ---"
bmd judge --check-json "$WORK/check.json"; JUDGE_RC=$?
say "judge exit $JUDGE_RC"

record "$LIST_RC" "$CHECK_RC" "$JUDGE_RC"
