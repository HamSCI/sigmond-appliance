#!/bin/bash
# test-rig-flash.sh — rig-flash.sh must never pick the wrong disk.
#
# ⛔ THE DISK IT MUST NOT TOUCH.  The build rig's /dev/sda is an INTERNAL 500 GB
# WD spinning disk (removable=0), and its system is on nvme0n1.  A hardcoded
# device, or "the first disk that isn't nvme", destroys that drive.  Selection
# is by ATTRIBUTE -- USB-attached AND removable AND under the cap -- and must
# refuse unless exactly one qualifies.
#
# Runs against a fake /sys in a mount namespace: no root, no disks, no risk.
set -u
cd "$(dirname "$0")" || exit 1
REPO=$PWD
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }

bash -n rig-flash.sh || { echo "FATAL: rig-flash.sh does not parse"; exit 1; }

# disk <name> <removable> <usb?> <sectors>
mkdisk(){
    local root="$1" n="$2" rem="$3" usb="$4" sz="$5"
    # ⚠ NOT mkdir .../device -- `ln -s` into an existing directory puts the
    # link INSIDE it, so /sys/block/<n>/device stayed a directory, readlink
    # returned nothing, and every fake disk looked non-USB.
    mkdir -p "$root/sys/$n"
    echo "$rem" > "$root/sys/$n/removable"
    echo "$sz"  > "$root/sys/$n/size"
    mkdir -p "$root/sys/.bus"
    # ⚠ The target must live INSIDE the bound tree.  /sys/block is the bind
    # mount, so a symlink escaping it resolves to a path that does not exist in
    # the namespace, readlink -f returns nothing, and every disk silently looks
    # non-USB -- the harness would then "pass" by finding no stick at all.
    if [ "$usb" = usb ]; then
        mkdir -p "$root/sys/.bus/usb1/$n"; ln -sfn "../.bus/usb1/$n" "$root/sys/$n/device"
    else
        mkdir -p "$root/sys/.bus/ata1/$n"; ln -sfn "../.bus/ata1/$n" "$root/sys/$n/device"
    fi
}

run(){   # run <label> <setup-fn>
    local root="$W/root"; rm -rf "$root"; mkdir -p "$root/sys" "$root/build" "$root/bin"
    "$2" "$root"
    : > "$root/build/sigmond-appliance-v9.99-20260101-release.img"
    printf '#!/bin/bash\necho "  DD-CALLED $*" >> "$W/ddlog"\nexit 0\n' > "$root/bin/dd"
    printf '#!/bin/bash\nexit 0\n' > "$root/bin/umount"
    printf '#!/bin/bash\nexit 0\n' > "$root/bin/sync"
    chmod +x "$root"/bin/*
    : > "$W/ddlog"
    # No bind for the build dir: the path is already configurable, and mkdir
    # under a userns fake-root cannot write to the real /.  Only /sys/block
    # has to be faked.
    SIGMOND_BUILD_DIR="$root/build" W="$W" unshare -rm bash -c '
        root="$1"; shift
        mount --bind "$root/sys" /sys/block
        export PATH="$root/bin:$PATH"
        exec "$@"
    ' _ "$root" bash "$REPO/rig-flash.sh" 2>&1
}

# ── the rig as it actually is: internal WD + nvme, no stick ────────────────
setup_rig_no_stick(){ mkdisk "$1" sda 0 ata 976773168; mkdisk "$1" nvme0n1 0 ata 976773168; }
out=$(run "rig, no stick" setup_rig_no_stick); rc=$?
case "$out" in *"NO USB STICK"*) ok "says so when no stick is present" ;;
               *) bad "says so when no stick is present: $out" ;; esac
[ "$rc" = 2 ] && ok "exits 2 (nothing wrong) not 1" || bad "exits 2, got $rc"
grep -q DD-CALLED "$W/ddlog" && bad "MUST NOT write with no stick" || ok "writes nothing with no stick"

# ── ⛔ the internal 500 GB WD must never be chosen ─────────────────────────
out=$(run "internal only" setup_rig_no_stick)
case "$out" in *"/dev/sda"*) bad "NAMED the internal disk as a target" ;;
               *) ok "never names the internal disk as a target" ;; esac

# ── ⛔ THE DISASTER CASE: one internal disk, nothing else ──────────────────
# With two disks present, dropping the removable/usb filters merely makes the
# selection ambiguous and it refuses -- so the earlier assertions pass while
# the guard is gone.  A machine with a SINGLE internal disk is where that
# mistake actually writes: the only candidate is the system drive.
setup_single_internal(){ mkdisk "$1" sda 0 ata 976773168; }
out=$(run "single internal disk" setup_single_internal)
case "$out" in *"NO USB STICK"*) ok "a lone internal disk is not a target" ;;
               *) bad "a lone internal disk is not a target: $(echo "$out" | tail -1)" ;; esac
grep -q DD-CALLED "$W/ddlog" && bad "MUST NOT write to a lone internal disk" \
                             || ok "writes nothing to a lone internal disk"

# ── ⛔ AND a SMALL internal disk, which the size cap cannot save ───────────
# The rig's WD is 465 GB, so the size cap rejects it even with the
# removable/usb filters gone -- which masks whether those filters work at all.
# Plenty of machines boot from a 32 GB eMMC or small SSD.  There, the cap
# passes and only the removable/usb test stands between the tool and the
# system disk.
setup_small_internal(){ mkdisk "$1" sda 0 ata 62914560; }   # 30 GiB, internal
out=$(run "small internal disk" setup_small_internal)
case "$out" in *"NO USB STICK"*) ok "a SMALL internal disk is not a target" ;;
               *) bad "a SMALL internal disk is not a target: $(echo "$out" | tail -1)" ;; esac
grep -q DD-CALLED "$W/ddlog" && bad "MUST NOT write to a small internal disk" \
                             || ok "writes nothing to a small internal disk"

# ── a genuine stick alongside the internal disk ────────────────────────────
setup_with_stick(){ mkdisk "$1" sda 0 ata 976773168; mkdisk "$1" nvme0n1 0 ata 976773168
                    mkdisk "$1" sdb 1 usb 61440000; }
out=$(run "stick present" setup_with_stick)
case "$out" in *"target /dev/sdb"*) ok "picks the USB removable stick" ;;
               *) bad "picks the USB removable stick: $(echo "$out" | tail -2)" ;; esac

# ── two sticks: refuse rather than guess ───────────────────────────────────
setup_two(){ setup_with_stick "$1"; mkdisk "$1" sdc 1 usb 61440000; }
out=$(run "two sticks" setup_two)
case "$out" in *"exactly one"*) ok "refuses when two sticks are present" ;;
               *) bad "refuses when two sticks are present" ;; esac
grep -q DD-CALLED "$W/ddlog" && bad "MUST NOT write when ambiguous" || ok "writes nothing when ambiguous"

# ── a big USB disk (someone's backup drive) is not a target ────────────────
# 5 TB: comfortably over the 1 TB cap, i.e. someone's backup drive.
setup_big_usb(){ mkdisk "$1" sda 0 ata 976773168; mkdisk "$1" sdb 1 usb 9767731680; }
out=$(run "big usb" setup_big_usb)
case "$out" in *"NO USB STICK"*) ok "ignores a USB disk over the size cap" ;;
               *) bad "ignores a USB disk over the size cap" ;; esac

# ── the card actually in the rig: a 238 GiB microSD in a USB adapter ──────
# This is the real device, and the old 256 GB cap left it one notch from being
# rejected.  Cards grow; the cap must not be the thing that fails.
setup_microsd(){ mkdisk "$1" sda 0 ata 976773168; mkdisk "$1" sdb 1 usb 500118192; }
out=$(run "238 GiB microSD" setup_microsd)
case "$out" in *"target /dev/sdb"*) ok "a 238 GiB card qualifies" ;;
               *) bad "a 238 GiB card qualifies: $(echo "$out" | tail -1)" ;; esac

echo; printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
