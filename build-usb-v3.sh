#!/bin/bash
# Sigmond appliance USB image builder v3 — runs on B3 in ~/appliance/v3.
#
# v3 over v2:
#   - EXPLICIT VERSION per image (from the git tag on HEAD, e.g. v3.0) baked
#     into: the image filename, the Proxmox host fqdn, the decoder VM name,
#     /etc/motd, QUICKSTART — so test sticks are never confused (rob
#     2026-07-26; tag-derived since Stage 2 so every image traces to a commit).
#   - the SIGMOND REPO rides in the payload (host tuning scripts:
#     host-discover/host-apply/cpu-pin template used by the importer).
#   - image is SHIPPED TO wd30 IMMEDIATELY after build, before testing,
#     so rob/Michael can download+burn in parallel with the nested test.
#
# Packaging rules (hard-won, June 2026):
#   - ISO bytes stay PRISTINE; payload appended at the 1MiB-aligned
#     iso9660 volsize offset. NEVER a GPT partition for the payload.
#   - reboot-mode = "power-off" stays: remove-the-stick cue + loop guard.
#
# Usage: build-usb-v3.sh [--release] [--no-ship] [--dev]
#   Version comes from the git tag on HEAD in the sigmond-appliance checkout
#   (tag it first: git tag v3.32).  --dev allows an untagged build instead,
#   stamped v0.0-dev+<sha> so it can never pass as, or be blessed as, a
#   release.  A dirty working tree aborts unless --dev is given.
set -eu
say(){ echo "[usb $(date '+%T')] $*"; }
die(){ say "FATAL: $*"; exit 1; }

# RIG_ROOT is the parent that holds v3 plus its build-rig siblings (build/,
# sigmond-ref/, vmbuild/). Everything below resolves off it explicitly
# rather than via "../sibling" from inside v3: the kernel resolves ".."
# PHYSICALLY, so if v3 is ever a symlink into a different physical location
# (it was, briefly, when the rig moved off B3's root disk to relieve disk
# pressure) every "../X" silently starts pointing at a nonexistent sibling
# of the physical target instead of the logical one -- bash's own $PWD still
# reports the pre-move path, so the breakage doesn't show until a build
# fails partway through. Resolving from RIG_ROOT sidesteps that: normal
# absolute-path symlink resolution is used instead of physical ".." lookup.
RIG_ROOT="${APPLIANCE_RIG_ROOT:-$HOME/appliance}"
[ -d "$RIG_ROOT" ] || die "rig root missing: $RIG_ROOT (check APPLIANCE_RIG_ROOT)"
cd "$RIG_ROOT/v3" || die "rig v3 checkout missing: $RIG_ROOT/v3 (check APPLIANCE_RIG_ROOT)"
LOG="$PWD/usb-build.log"
exec > >(tee -a "$LOG") 2>&1

# REPO is the git checkout this script itself ships from -- not $PWD, which
# is the build rig staging dir ($RIG_ROOT/v3) and isn't under git.
# Same override pattern as SIGMOND_REPO below.
REPO="${APPLIANCE_REPO:-$HOME/appliance/repos/sigmond-appliance}"
# A bad REPO must abort, not degrade quietly: if $REPO is missing or not a
# git checkout, `git -C "$REPO" status --porcelain` fails to stderr and the
# command substitution below captures nothing, which reads as "clean" and
# silently skips the dirty-tree gate this task exists to add.  Fail loudly
# up front instead.
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
    || die "not a git checkout: $REPO (check APPLIANCE_REPO)"
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null \
    || die "no commits in $REPO — nothing to tag"

# BUILD_DIR and SIGMOND_REF_DIR are the other two rig siblings this script
# touches (vmbuild/ belongs to build-golden-vm.sh only). BUILD_DIR must
# already exist and be populated (answer.toml lives there); SIGMOND_REF_DIR
# is allowed to not exist yet -- it's created below by git clone the first
# time this runs on a rig -- so only its parent (RIG_ROOT, already checked
# above) needs to be real.
BUILD_DIR="${APPLIANCE_BUILD_DIR:-$RIG_ROOT/build}"
SIGMOND_REF_DIR="${APPLIANCE_SIGMOND_REF_DIR:-$RIG_ROOT/sigmond-ref}"
[ -d "$BUILD_DIR" ] || die "build dir missing: $BUILD_DIR (check APPLIANCE_BUILD_DIR)"

RELEASE=0; SHIP=1; DEV=0
for a in "$@"; do
    case "$a" in
        --release) RELEASE=1 ;;
        --no-ship) SHIP=0 ;;
        --dev) DEV=1 ;;
        v[0-9]*) die "'$a' looks like the old positional version argument -- version now comes from the git tag on HEAD (git tag $a in $REPO), not from a typed argument. Pass --dev for an untagged build." ;;
        *) die "unrecognized argument: $a" ;;
    esac
done

# Loud, not quiet: a `git status` failure here (permissions, corruption) must
# not read the same as "tree is clean" -- die rather than let $DIRTY default
# to empty.
DIRTY="$(git -C "$REPO" status --porcelain)" || die "git status failed in $REPO"
if [ -n "$DIRTY" ]; then
    (( DEV )) || die "working tree is dirty ($REPO) — commit or stash before building a release image"
fi

# `describe --tags --exact-match` deterministically prefers an annotated tag
# over a lightweight one on the same commit, so this isn't a correctness bug
# today -- but a leftover test tag (see the verification steps for this
# script) could silently outrank an intended release tag on a later build.
TAGS_AT_HEAD="$(git -C "$REPO" tag --points-at HEAD)"
if [ "$(printf '%s\n' "$TAGS_AT_HEAD" | grep -c .)" -gt 1 ]; then
    say "WARN: multiple tags on HEAD in $REPO ($(printf '%s' "$TAGS_AT_HEAD" | tr '\n' ' ')) — describe prefers the annotated one; delete any stray tag if that's not the intended release"
fi

VERSION="$(git -C "$REPO" describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ -z "$VERSION" ]; then
    if (( DEV )); then
        VERSION="v0.0-dev+$(git -C "$REPO" rev-parse --short HEAD)"
    else
        die "HEAD is not tagged. Tag the release first (git tag v3.32) or pass --dev."
    fi
fi
case "$VERSION" in v[0-9]*) ;; *) say "FATAL: version must look like v3.0"; exit 1;; esac
VTAG="${VERSION//./-}"

SRC_ISO="$HOME/appliance/iso/proxmox-ve_9.1-1.iso"
TPL=sigmond-decoder-template-v3.qcow2
[ -f "$SRC_ISO" ] || { say "FATAL: $SRC_ISO missing"; exit 1; }
[ -f "$TPL" ] || { say "FATAL: $TPL missing (build the golden VM first)"; exit 1; }
# The wizard is versioned in HamSCI/sigmond (scripts/proxmox/sigmond-wizard.sh)
# as of 0774d81.  Take it from the checkout rather than a local copy: it used
# to live only in this rig, unversioned, and the whole point of putting it in
# the repo was to stop the rig and the repo drifting.  Refuse to build from a
# checkout whose wizard is uncommitted, and warn if the checkout is not at
# origin/main -- the image would otherwise ship something nobody can identify.
SIGMOND_REPO="${SIGMOND_REPO:-$HOME/appliance/repos/sigmond}"
WIZ_SRC="$SIGMOND_REPO/scripts/proxmox/sigmond-wizard.sh"
[ -f "$WIZ_SRC" ] || { say "FATAL: wizard missing at $WIZ_SRC"; exit 1; }
if [ -n "$(git -C "$SIGMOND_REPO" status --porcelain -- scripts/proxmox/sigmond-wizard.sh 2>/dev/null)" ]; then
    say "FATAL: $WIZ_SRC has uncommitted changes — commit and push first"; exit 1
fi
git -C "$SIGMOND_REPO" fetch origin >/dev/null 2>&1 || true
_wiz_head=$(git -C "$SIGMOND_REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
if [ "$(git -C "$SIGMOND_REPO" rev-parse HEAD 2>/dev/null)" \
   != "$(git -C "$SIGMOND_REPO" rev-parse origin/main 2>/dev/null)" ]; then
    say "WARN: sigmond checkout at $_wiz_head is not origin/main — wizard may be stale"
fi
cp "$WIZ_SRC" sigmond-wizard.sh
say "wizard sourced from sigmond $_wiz_head ($(wc -l < sigmond-wizard.sh) lines)"
[ -f sigmond-wizard.sh ] || { say "FATAL: sigmond-wizard.sh missing"; exit 1; }
[ -f firstboot-v3.sh ] || { say "FATAL: firstboot-v3.sh missing"; exit 1; }

say "=== building sigmond-appliance $VERSION (tag $VTAG, release=$RELEASE) ==="

say "answer file (fqdn carries the version)"
[ -f "$BUILD_DIR/answer.toml" ] || die "answer.toml missing: $BUILD_DIR/answer.toml (check APPLIANCE_BUILD_DIR)"
sed -e "s|^fqdn = .*|fqdn = \"sigmond-appliance-${VTAG}.local\"|" \
    "$BUILD_DIR/answer.toml" > answer-v3.toml
grep -q "sigmond-appliance-${VTAG}" answer-v3.toml || { say "FATAL: fqdn substitution failed"; exit 1; }
if [ "$RELEASE" = 1 ]; then
    sed -i '/^root-ssh-keys/d' answer-v3.toml
    say "release mode: test ssh key stripped"
fi
grep -q 'reboot-mode = "power-off"' answer-v3.toml || { say "FATAL: answer.toml lost power-off mode"; exit 1; }

say "firstboot + quickstart + wizard (version substitution)"
sed -e "s|@@VERSION@@|${VERSION}|g" firstboot-v3.sh > firstboot-rendered.sh
sed -e "s|@@VERSION@@|${VERSION}|g" -e "s|@@VTAG@@|${VTAG}|g" QUICKSTART.txt > QUICKSTART-rendered.txt
# decoder VM is VMID 100 in v3 (fleet convention); wizard default was 120
sed -e 's|SIGMOND_VMID:-120|SIGMOND_VMID:-100|g' \
    -e 's|"SIGMOND_VMID", "120"|"SIGMOND_VMID", "100"|g' sigmond-wizard.sh > sigmond-wizard-rendered.sh
if grep -q '120' sigmond-wizard-rendered.sh; then
    grep -n '120' sigmond-wizard-rendered.sh | grep -qiv 'timeout\|sleep\|port\|freq\|OnUnitActiveSec' && say "WARN: wizard still mentions 120 somewhere — check"
fi

say "sigmond repo payload (host tuning scripts ride on the stick)"
if [ ! -d "$SIGMOND_REF_DIR/.git" ]; then
    git clone -q --depth 1 git@github.com:HamSCI/sigmond "$SIGMOND_REF_DIR"
fi
git -C "$SIGMOND_REF_DIR" pull -q 2>/dev/null || true
SIGREV=$(git -C "$SIGMOND_REF_DIR" rev-parse --short HEAD)
# `tar -C ..` is the same physical-vs-logical trap as a bare "../X": it
# changes tar's cwd to the physical parent of the process cwd, not the
# logical one. Use SIGMOND_REF_DIR's own parent/basename instead so this
# still works if APPLIANCE_SIGMOND_REF_DIR ever points somewhere other than
# directly under RIG_ROOT.
#
# SIGMOND_REF_DIR itself can be a symlink (it was made one during a rig disk
# migration, 2026-08-16: RIG_ROOT/sigmond-ref -> /srv/build/sigmond-ref, to
# get the checkout off B3's root disk). tar with no dereference flag stores
# a symlink ARGUMENT as a symlink entry -- it does not follow it -- so the
# archive ended up as one 127-byte "sigmond -> /srv/build/sigmond-ref" entry
# instead of the tree, and every install got a broken symlink where the
# sigmond payload should be. Resolve SIGMOND_REF_DIR to its physical path
# before handing it to tar so the argument tar sees is a real directory.
# Deliberately NOT `tar -h`/`--dereference`: that would also follow any
# symlink tar finds WALKING THE TREE, silently changing what ships (e.g. a
# vendored symlink turned into a copy of its target). Resolving only the
# top-level path fixes exactly the broken thing.
SIGMOND_REF_REAL="$(readlink -f "$SIGMOND_REF_DIR")" \
    || die "cannot resolve sigmond ref dir: $SIGMOND_REF_DIR"
[ -d "$SIGMOND_REF_REAL" ] \
    || die "sigmond ref dir resolves to a non-directory: $SIGMOND_REF_DIR -> $SIGMOND_REF_REAL"
tar czf sigmond.tar.gz -C "$(dirname "$SIGMOND_REF_REAL")" \
    --transform 's|^sigmond-ref|sigmond|' "$(basename "$SIGMOND_REF_REAL")"
# A source tree that shrinks to a broken-symlink-sized archive must fail the
# build, not ship. 4096 bytes and 10 entries are both comfortably below any
# real (hundreds of files) sigmond checkout, and comfortably above the
# 127-byte, 1-entry archive this exact defect produced.
SIGMOND_TAR_BYTES=$(stat -c%s sigmond.tar.gz)
SIGMOND_TAR_ENTRIES=$(tar tzf sigmond.tar.gz | wc -l)
[ "$SIGMOND_TAR_BYTES" -ge 4096 ] \
    || die "sigmond.tar.gz is only ${SIGMOND_TAR_BYTES} bytes -- looks like a broken symlink, not the sigmond source tree (check $SIGMOND_REF_DIR)"
[ "$SIGMOND_TAR_ENTRIES" -ge 10 ] \
    || die "sigmond.tar.gz has only ${SIGMOND_TAR_ENTRIES} entries -- looks like a broken symlink, not the sigmond source tree (check $SIGMOND_REF_DIR)"
say "sigmond payload @ $SIGREV ($SIGMOND_TAR_BYTES bytes, $SIGMOND_TAR_ENTRIES entries)"

say "sigmond-rac payload"
if [ ! -d sigmond-rac ]; then
    git clone -q https://github.com/HamSCI/sigmond-rac sigmond-rac
fi
git -C sigmond-rac pull -q 2>/dev/null || true
tar czf sigmond-rac.tar.gz sigmond-rac
# sigmond-rac is a fresh git clone directly under $PWD (not a rig-sibling
# path that can be a symlink), but the same broken-payload class of bug is
# cheap to guard against here too.
SIGMOND_RAC_TAR_BYTES=$(stat -c%s sigmond-rac.tar.gz)
SIGMOND_RAC_TAR_ENTRIES=$(tar tzf sigmond-rac.tar.gz | wc -l)
[ "$SIGMOND_RAC_TAR_BYTES" -ge 1024 ] \
    || die "sigmond-rac.tar.gz is only ${SIGMOND_RAC_TAR_BYTES} bytes -- looks broken, not the sigmond-rac source tree"
[ "$SIGMOND_RAC_TAR_ENTRIES" -ge 2 ] \
    || die "sigmond-rac.tar.gz has only ${SIGMOND_RAC_TAR_ENTRIES} entries -- looks broken, not the sigmond-rac source tree"

say "prepare-iso (embed answer + firstboot)"
# a stale .tmp from an interrupted run makes xorriso append to a full image
# ("Image size ... exceeds free space on media 0s" — killed the first v3.4
# build 2026-07-27); the assistant writes it next to the SOURCE iso
rm -f pve-sc-v3.iso "$(dirname "$SRC_ISO")"/pve-sc-v3.iso.tmp
proxmox-auto-install-assistant prepare-iso "$SRC_ISO" \
    --fetch-from iso --answer-file answer-v3.toml \
    --on-first-boot firstboot-rendered.sh --output pve-sc-v3.iso
[ -f pve-sc-v3.iso ] || { say "FATAL: prepare-iso produced nothing"; exit 1; }

say "ESP FAT12→FAT16 in-place conversion (AMI firmwares silently refuse FAT12"
say "ESPs on USB media — B4 AZW SER offered no boot option, 2026-07-26)"
ESP_START=$(sgdisk -i 2 pve-sc-v3.iso 2>/dev/null | awk '/First sector/{print $3}')
ESP_END=$(sgdisk -i 2 pve-sc-v3.iso 2>/dev/null | awk '/Last sector/{print $3}')
[ -n "$ESP_START" ] && [ -n "$ESP_END" ] || { say "FATAL: cannot locate ESP in prepared iso"; exit 1; }
ESP_SECS=$(( ESP_END - ESP_START + 1 ))
rm -rf /tmp/espfix.$$; mkdir -p /tmp/espfix.$$/old /tmp/espfix.$$/new
dd if=pve-sc-v3.iso of=/tmp/espfix.$$/esp-old.bin bs=512 skip="$ESP_START" count="$ESP_SECS" status=none
mount -o ro,loop /tmp/espfix.$$/esp-old.bin /tmp/espfix.$$/old
dd if=/dev/zero of=/tmp/espfix.$$/esp-new.bin bs=512 count="$ESP_SECS" status=none
/usr/sbin/mkfs.vfat -F 16 -s 1 /tmp/espfix.$$/esp-new.bin >/dev/null
mount -o loop /tmp/espfix.$$/esp-new.bin /tmp/espfix.$$/new
cp -r /tmp/espfix.$$/old/. /tmp/espfix.$$/new/
umount /tmp/espfix.$$/old /tmp/espfix.$$/new
file /tmp/espfix.$$/esp-new.bin | grep -q "FAT (16 bit)" || { say "FATAL: ESP rebuild is not FAT16"; exit 1; }
dd if=/tmp/espfix.$$/esp-new.bin of=pve-sc-v3.iso bs=512 seek="$ESP_START" conv=notrunc status=none
rm -rf /tmp/espfix.$$
say "ESP rewritten as FAT16 at sectors ${ESP_START}-${ESP_END} (contents identical)"

say "MBR active flag on partition entry 1 (legacy AMI BIOSes refuse disks"
say "with no 0x80 active partition — Kamrui mini PC, 2026-07-27; UEFI ignores it)"
printf '\x80' | dd of=pve-sc-v3.iso bs=1 seek=446 conv=notrunc status=none

# Component pin manifest, host copy (Stage 3, Task 1): built now, before the
# payload, so it can ride inside it. It CANNOT carry this build's
# image_sha256 -- that is the hash of the finished .img, which does not
# exist until after the payload (and whatever it contains) is already
# sealed inside it; a self-referential hash would just be a lie the moment
# mkfs writes it. Everything else a host needs to answer "am I what my
# image says I am" -- version, commit, tag, build time, component pins --
# is already known here. Same gate as the Release-attached copy below
# (manifest-raw.txt must exist and look like a real ~20-component capture,
# not truncated); re-checked independently there too, same reasoning as the
# sigmond/sigmond-rac tarball re-checks: the file could go stale or get
# hand-edited between the two checks.
say "component pin manifest (host copy, pre-payload)"
if [ ! -f manifest-raw.txt ]; then
    die "manifest-raw.txt missing — the golden VM build did not capture smd version (see build-golden-vm.sh output); an image cannot be blessed without a manifest. Rebuild the golden VM or fix the capture before shipping."
fi
NCOMP_HOST=$(grep -c '^    [A-Za-z]' manifest-raw.txt 2>/dev/null || true); NCOMP_HOST=${NCOMP_HOST:-0}
if [ "$NCOMP_HOST" -lt 10 ]; then
    die "manifest-raw.txt has only $NCOMP_HOST component line(s) — looks truncated, not a real ~20-component capture; refusing to ship a manifest that lies. Rebuild the golden VM."
fi
BUILT_UTC="$(date -u -Iseconds)"
{
    echo "image_version: $VERSION"
    echo "appliance_commit: $(git -C "$REPO" rev-parse HEAD)"
    echo "appliance_tag: $VERSION"
    echo "built_utc: $BUILT_UTC"
    # Explained here, not just in this build script's comments, because a
    # field engineer reads THIS file, not build-usb-v3.sh. Sits above the
    # "components (live):" header, so manifest_drift()'s parser -- which
    # only starts reading at that literal line -- never sees it.
    echo "# image_sha256: intentionally absent from this host copy. It is the"
    echo "#   hash of the finished .img, which does not exist until after this"
    echo "#   payload is already sealed inside it -- a self-referential"
    echo "#   checksum would just be wrong the moment it was written. This is"
    echo "#   not corruption. For the image checksum, see the Release-attached"
    echo "#   manifest for this exact build (same appliance_commit + built_utc"
    echo "#   above): sigmond-appliance-${VERSION}-<stamp>.manifest.txt on the"
    echo "#   GitHub Release, or the artifact store."
    echo
    cat manifest-raw.txt
} > manifest-host.txt
say "host manifest written: manifest-host.txt ($NCOMP_HOST component rows)"

say "payload ext4 (template + wizard + sigmond + rac + quickstart)"
PAYSZ_MB=$(( $(stat -c%s "$TPL")/1048576 + $(stat -c%s sigmond.tar.gz)/1048576 + $(stat -c%s sigmond-rac.tar.gz)/1048576 + 320 ))
rm -f payload-v3.ext4
dd if=/dev/zero of=payload-v3.ext4 bs=1M count="$PAYSZ_MB" status=none
/usr/sbin/mkfs.ext4 -q -L SIGTPL payload-v3.ext4
mkdir -p /tmp/sigpay.$$
mount -o loop payload-v3.ext4 /tmp/sigpay.$$
cp "$TPL" sigmond.tar.gz sigmond-rac.tar.gz /tmp/sigpay.$$/
cp sigmond-wizard-rendered.sh /tmp/sigpay.$$/sigmond-wizard.sh
cp QUICKSTART-rendered.txt /tmp/sigpay.$$/QUICKSTART.txt
# FFT wisdom seed (from the live B4 appliance VM, fftw 3.3.10): smd apply
# gates radiod START on /etc/fftw/wisdomf existing, and the in-VM planner
# grinds for over an hour on first boot — the wizard pushes this seed so
# radiod starts immediately (fftw ignores entries that don't match the CPU)
WSEED=""
[ -f wisdomf-seed ] && WSEED=wisdomf-seed
[ -z "$WSEED" ] && [ -f wisdomf-ryzen5825u ] && WSEED=wisdomf-ryzen5825u
[ -n "$WSEED" ] && cp "$WSEED" /tmp/sigpay.$$/wisdomf-seed \
  || say "WARN: no wisdom seed in rig — first radiod start may wait on the planner"
# site-timing auto-wiring helper (chrony refclocks, LAN NTP/GNSS discovery,
# metrology channels, full timestd profile) — pushed into the VM by the wizard
[ -f sigmond-site-timing ] && cp sigmond-site-timing /tmp/sigpay.$$/ \
  || say "WARN: sigmond-site-timing missing from rig — timing chain manual"
# operator shell helpers (tm/ll/lrt) for host + VM /etc/profile.d
[ -f sigmond-operator.sh ] && cp sigmond-operator.sh /tmp/sigpay.$$/
# location authority (GPSDO definitive over operator entry)
[ -f sigmond-location-check ] && cp sigmond-location-check /tmp/sigpay.$$/
echo "$VERSION sigmond@$SIGREV built $(date -Iseconds)" > /tmp/sigpay.$$/VERSION
# component pin manifest (host copy, no image_sha256 -- see above); named
# without the versioned/timestamped prefix so firstboot never has to know
# it, unlike the *.manifest.txt filename this build also produces below
cp manifest-host.txt /tmp/sigpay.$$/manifest.txt
umount /tmp/sigpay.$$; rmdir /tmp/sigpay.$$

STAMP="$(date +%Y%m%d)"
SUFFIX=""; [ "$RELEASE" = 1 ] && SUFFIX="-release"
IMG="sigmond-appliance-${VERSION}-${STAMP}${SUFFIX}.img"
say "assemble USB image (pristine ISO + payload at aligned volsize offset) -> $IMG"
VB=$(od -An -tu4 -j $((16*2048+80)) -N4 pve-sc-v3.iso | tr -d ' ')
OFF=$(( VB*2048 )); OFF=$(( (OFF+1048575)/1048576*1048576 ))
say "iso volsize=$((VB*2048)) bytes -> payload offset=$OFF"
rm -f "$IMG"
cp pve-sc-v3.iso "$IMG"
truncate -s "$OFF" "$IMG"
cat payload-v3.ext4 >> "$IMG"

# Publish the RAW .img — no compression (rob 2026-08-09).
# Measured over v3.21/22/23: xz lands at 90.7% every time, saving ~464 MB on
# a ~5 GB image for 2 min 36 s of build time plus the operator's decompress.
# The payload is already-compressed data (squashfs Proxmox ISO + a compacted
# qcow2 template), so xz grinds on incompressible bytes for 9%.
#
# The decisive argument is safety, not speed: compression is the direct cause
# of the worst failure this fleet has had -- Raspberry Pi Imager writing the
# COMPRESSED bytes verbatim to the stick, which looks written and silently
# will not boot (hit with .zst 2026-07-26, then again with .img.xz 2026-07-27).
# Shipping raw deletes that class outright: there is no decompress step to get
# wrong and no GUI writer to mishandle.  wd30 can still compress on demand for
# a slow-link site without the build or the burn path depending on it.
say "checksum (publishing the RAW .img — no compression; see the note above)"
rm -f "$IMG.xz"
sha256sum "$IMG" | tee "${IMG%.img}.sha256"
ls -la "$IMG"

# The component pin manifest: what a Release attaches, and the only record
# of which commit of each of the ~20 components (ka9q-radio, hf-timestd,
# wspr-recorder, ...) rode into this image. build-golden-vm.sh captures the
# raw `smd version` block from inside the template (the only place it can be
# captured — smd version doesn't work on B3 itself) into manifest-raw.txt,
# gating on both presence and row count there. This is the hard gate: no
# manifest, or a manifest that looks truncated, means no ship. A hand-typed
# pin drifts silently, so this file is generated only, never edited by hand.
# This is the Release-attached copy (with image_sha256); the payload already
# got its own copy of the same content, minus that one field, before the
# image existed to be hashed -- see "component pin manifest (host copy..."
# above.
say "component pin manifest"
if [ ! -f manifest-raw.txt ]; then
    rm -f "$IMG" "${IMG%.img}.sha256"
    die "manifest-raw.txt missing — the golden VM build did not capture smd version (see build-golden-vm.sh output); an image cannot be blessed without a manifest. Rebuild the golden VM or fix the capture before shipping. ($IMG and its .sha256 removed so they don't linger for the next run)"
fi
# Defense in depth: re-check row count here too, not just existence -- this
# is the actual ship/no-ship gate, and manifest-raw.txt could in principle
# be stale or hand-edited between a golden-VM run and this one. Same floor
# as build-golden-vm.sh's capture-time check.
# `|| true` is required here (unlike the read-only version of this check):
# grep -c exits 1 on zero matches even though it prints "0", and this script
# runs under `set -eu` -- a bare `VAR=$(grep -c ...)` with no `|| true`
# aborts the WHOLE SCRIPT right there on a truncated (0-row) capture, before
# the die() message and before the $IMG/.sha256 cleanup below ever run. That
# is exactly the case this gate exists to catch, so a silent set -e exit
# here would be worse than not having the gate at all.
NCOMP=$(grep -c '^    [A-Za-z]' manifest-raw.txt 2>/dev/null || true); NCOMP=${NCOMP:-0}
if [ "$NCOMP" -lt 10 ]; then
    rm -f "$IMG" "${IMG%.img}.sha256"
    die "manifest-raw.txt has only $NCOMP component line(s) — looks truncated, not a real ~20-component capture; refusing to ship a manifest that lies. Rebuild the golden VM. ($IMG and its .sha256 removed so they don't linger for the next run)"
fi
# Same content as the payload's manifest.txt (host copy, written earlier
# alongside the payload build) plus the one field that copy structurally
# cannot carry: image_sha256, the hash of this now-finished .img. $BUILT_UTC
# is reused rather than re-stamped so the two copies agree on build time too.
MANIFEST="${IMG%.img}.manifest.txt"
{
    echo "image_version: $VERSION"
    echo "appliance_commit: $(git -C "$REPO" rev-parse HEAD)"
    echo "appliance_tag: $VERSION"
    echo "built_utc: $BUILT_UTC"
    echo "image_sha256: $(cut -d' ' -f1 < "${IMG%.img}.sha256")"
    echo
    cat manifest-raw.txt
} > "$MANIFEST"
say "manifest written: $MANIFEST"

if [ "$SHIP" = 1 ]; then
    say "SHIPPING to wd30 NOW (untested — test verdict follows separately)"
    scp -q "$IMG" "${IMG%.img}.sha256" "$MANIFEST" wd30:~/ \
        && say "shipped: wd30:~/$IMG + .sha256 + .manifest.txt" \
        || say "WARNING: ship to wd30 FAILED — ship manually"
fi
say "USB IMAGE BUILD COMPLETE: $VERSION ($IMG)"
