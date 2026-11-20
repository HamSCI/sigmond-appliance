#!/bin/bash
# v3 golden decoder VM build driver — runs ON B3, logs to ~/appliance/v3/build.log
# provision.sh clones HamSCI/sigmond and checks out SIGMOND_COMMIT (default:
# the head of main, read once here); provision-components.sh installs that
# commit's release/components.toml.  ssh port 5557 to avoid any stale v2 rig.
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
# The one sigmond commit this template installs (C4).  Read once, here, so
# both stages and the record agree; an operator names a candidate's commit
# with SIGMOND_COMMIT=<40 hex>.  Its release/components.toml is the list the
# VM installs, so it must be pushed before the build.
SIGMOND_COMMIT="${SIGMOND_COMMIT:-$(git ls-remote https://github.com/HamSCI/sigmond refs/heads/main | cut -f1)}"
[[ "$SIGMOND_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || die "SIGMOND_COMMIT is '$SIGMOND_COMMIT', not a full 40-hex commit (set it, or check the network)"
say "sigmond commit under build: $SIGMOND_COMMIT"
# .new until the template is written, beside golden-v3-revs.txt.new: a build
# that fails a gate must leave the old template's record, never this one.
echo "$SIGMOND_COMMIT" > golden-v3-sigmond-commit.txt.new
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

# ⛔ The decoder VM's ssh key is not optional.  provision-components.sh once
# installed it only `if [ -f "$HOME/rob.pub" ]`, and on 2026-09-21 that file
# was absent on the rig, so the golden VM shipped with NO key-based access to
# the decoder VM.  It surfaced only when the guest agent went down on AI6VN
# and there was no remaining way in.  Refuse to build blind: the operator can
# still opt out explicitly.
#
# Keys now live one-per-operator in operators/*.pub (see operators/README.md)
# rather than in a single file named after one person.  We merge them here and
# COUNT KEYS, not files: an empty directory, a directory of pure comments and
# a missing directory all fail the same way, because they all produce the same
# lockout.  The legacy single-file paths stay readable so a rig that has not
# synced yet still builds -- loudly.
MERGED="$BUILD_DIR/operator-keys"
: > "$MERGED"
KEYSRC=""
if compgen -G "$PWD/operators/*.pub" >/dev/null 2>&1; then
    for f in "$PWD"/operators/*.pub; do
        printf '# --- %s\n' "$(basename "$f")" >> "$MERGED"
        cat "$f" >> "$MERGED"
        printf '\n' >> "$MERGED"
    done
    KEYSRC="$PWD/operators/"
else
    # Legacy: a single rob.pub beside the script or in $HOME.
    for c in "$PWD/rob.pub" "$HOME/rob.pub"; do
        [ -f "$c" ] && { cat "$c" >> "$MERGED"; KEYSRC="$c"; break; }
    done
    [ -n "$KEYSRC" ] && say "WARNING: using legacy key file $KEYSRC — this rig has
  not synced operators/.  Sync the checkout so added or REVOKED operators
  take effect; a stale key file is how v3.48-v3.50 shipped rob's key alone."
fi

# ssh-keygen -lf prints one line per key it can parse and ignores comments and
# junk, so its line count is the number of keys that will actually authorize.
NKEYS=$(ssh-keygen -lf "$MERGED" 2>/dev/null | wc -l)
if [ "${NKEYS:-0}" -eq 0 ]; then
    say "FATAL: no usable operator public key — the station would be built with"
    say "  NO authorized ssh key on either plane, leaving 'qm terminal 100' at"
    say "  the console as the only way in when the guest agent is unavailable."
    say "  Looked for: $PWD/operators/*.pub  then  $PWD/rob.pub  then  $HOME/rob.pub"
    [ -n "$KEYSRC" ] && say "  ($KEYSRC exists but yielded no parseable key — truncated or mangled?)"
    say "  Add operators/<name>.pub, or set VMKEYLESS_OK=1 to build anyway."
    [ "${VMKEYLESS_OK:-0}" = 1 ] || die "refusing to build a keyless station"
    say "  VMKEYLESS_OK=1 — continuing WITHOUT any operator ssh key"
    OPKEY=""
else
    # ⛔ A fingerprint appearing in two operator files means one of two
    # things and both are faults: the same key was copied under a second
    # person's name (misattribution -- caught exactly this way on 2026-09-23,
    # when mjh.pub was written holding rob's devbox key), or two people share
    # a private key.  Either way the set can no longer say who holds root,
    # and independent revocation -- the whole reason for one file per person
    # -- silently stops working.  Refuse.
    DUPFP=$(ssh-keygen -lf "$MERGED" 2>/dev/null | awk '{print $2}' | sort | uniq -d)
    if [ -n "$DUPFP" ]; then
        say "FATAL: the same key appears under more than one operator:"
        for _fp in $DUPFP; do
            say "  $_fp"
            for _f in "$PWD"/operators/*.pub; do
                ssh-keygen -lf "$_f" 2>/dev/null | grep -q "$_fp" \
                    && say "      in $(basename "$_f")"
            done
        done
        say "  One key per person, in that person's own file. Fix operators/ and rebuild."
        die "refusing to build with a duplicated operator key"
    fi
    OPKEY="$MERGED"
    say "operator keys: $NKEYS from $KEYSRC"
    ssh-keygen -lf "$MERGED" 2>/dev/null | while read -r bits fp comment _; do
        say "  $bits $fp $comment"
    done
fi
$SCP provision.sh provision-components.sh build@127.0.0.1:
[ -n "$OPKEY" ] && $SCP "$OPKEY" build@127.0.0.1:operator-keys
$SCP wisdomf-ryzen5825u build@127.0.0.1:wisdomf
# top(1) config showing P (last-used CPU) beside %CPU — baked into the
# golden VM so every operator account has it without a per-station step.
[ -f "$PWD/operator/toprc" ] && $SCP "$PWD/operator/toprc" build@127.0.0.1:toprc
# system-wide vim config (selects the industry colour scheme)
[ -f "$PWD/operator/vimrc.local" ] && $SCP "$PWD/operator/vimrc.local" build@127.0.0.1:vimrc.local
# radiod's own channel-filter plans — a DIFFERENT file from wisdomf, which
# is planned non-threaded and which radiod's threaded plans never match.
# Without this, radiod silently runs FFTW_ESTIMATE plans (see
# provision-components.sh).
$SCP wisdom-radiod-plans-ryzen5825u build@127.0.0.1:wisdom-radiod-plans
say "stage 1: bootstrap (clone HamSCI/sigmond at $SIGMOND_COMMIT + install.sh)"
$SSH "chmod +x provision*.sh && SIGMOND_COMMIT=$SIGMOND_COMMIT setsid ./provision.sh </dev/null >/dev/null 2>&1 &"
for i in $(seq 1 120); do
    $SSH "grep -q 'BOOTSTRAP DONE' provision.log" 2>/dev/null && break
    $SSH "grep -q '^### FATAL' provision.log" 2>/dev/null && break
    sleep 15
done
if $SSH "grep -q '^### FATAL' provision.log" 2>/dev/null; then
    say "FATAL: stage1 refused:"; $SSH "grep '^### FATAL' provision.log; tail -20 provision.log"; exit 1
fi
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
$SSH "SIGMOND_COMMIT=$SIGMOND_COMMIT setsid ./provision-components.sh </dev/null >/dev/null 2>&1 &"
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
$SSH "for d in /opt/git/sigmond/*/; do printf '%s %s\n' \"\$(basename \$d)\" \"\$(git -C \$d rev-parse --short HEAD 2>/dev/null)\"; done" | tee golden-v3-revs.txt.new
# ⛔ .new until the template is actually written: build-usb-v3.sh trusts this
# file to describe sigmond-decoder-template-v3.qcow2, and a rebuild that FAILS
# a gate below used to leave fresh revs beside the OLD template, so the stale
# template passed the USB build's sigmond gate (v3.68 pre-build review).

# ── does every checkout sit at the release list's commit? ───────────────
# The template installs sigmond's release/components.toml at $SIGMOND_COMMIT,
# not the top of main.  Ask the VM's own smd to compare every checkout with
# that list (the smd at that commit reads its own release/components.toml).
# --require-all: a listed row with no checkout is a mismatch too, so a
# component that never installed cannot pass as "not checked".
say "checking every checkout against release/components.toml at $SIGMOND_COMMIT"
$SSH 'smd admin release-list --check --require-all' > golden-v3-freshness.txt 2>&1
_rc=$?
sed 's/^/  /' golden-v3-freshness.txt
if [ "$_rc" -ne 0 ]; then
    say "FATAL: the template's checkouts differ from release/components.toml (exit $_rc)"
    say "  the image would not be the release it names; see golden-v3-freshness.txt"
    rm -f golden-v3-sigmond-commit.txt.new golden-v3-revs.txt.new
    exit 1
fi
say "every listed component sits at its release-list commit"

# The manifest that build-usb-v3.sh ships with the image and that a Release
# attaches — this is the only point in the pipeline where components are
# installed AND still reachable over ssh (smd version reports "no component
# checkouts found" on B3 itself; it only works run inside the appliance).
# Best-effort here, not fatal: a missing/malformed manifest-raw.txt must not
# silently produce an unmanifested image, but it also shouldn't waste a
# completed, otherwise-good template. build-usb-v3.sh is the hard gate — it
# refuses to ship without this file.
say "capturing component pin manifest (smd version) from the template"
$SSH 'smd version' > manifest-raw.txt.new 2>/dev/null
NCOMP=$(grep -c '^    [A-Za-z]' manifest-raw.txt.new 2>/dev/null || true); NCOMP=${NCOMP:-0}
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
if grep -q 'components (live):' manifest-raw.txt.new 2>/dev/null && [ "$NCOMP" -ge 10 ]; then
    say "manifest captured: $NCOMP component lines"
else
    say "WARNING: manifest capture FAILED or truncated ($NCOMP component lines) — image will be unblessable (manifest-raw.txt missing or malformed); build-usb-v3.sh will refuse to ship without it"
    rm -f manifest-raw.txt.new
fi
# The commits the native builds compiled, from the build records smd writes
# (/var/lib/sigmond/build-manifest/*.toml), and the commit each decoder's
# .provenance names.  build-usb-v3.sh puts them in the manifest preamble as
# native_built_<name>: <sha> and native_provenance_<name>: <sha>, and bless
# gate 9 refuses an image whose commits differ from sigmond's pins (v3.94:
# every pin comes from the release; no station keeps a pin file).  The
# manifest rows only show checkouts, and a checkout can sit at the pin beside
# a binary built elsewhere.  native_built_capture says whether all five lines
# arrived: ok, or failed (gate 9 FAILs on failed).
say "capturing the commits the native builds recorded"
{
    $SSH 'for f in /var/lib/sigmond/build-manifest/*.toml; do [ -f "$f" ] && cat "$f"; done' 2>/dev/null \
        | awk -F'"' '/^\[\[upstream\]\]/{n=""} /^name *=/{n=$2}
                     /^sha *=/{ if (n ~ /^(onion|wsjtx|ubersdr_wsprd)$/ && $2 ~ /^[0-9a-f]+$/ && length($2) == 40)
                                    print "native_built_" n ": " $2 }'
    for _d in wsjtx:wsjtx ubersdr:ubersdr_wsprd; do
        _p="$($SSH "head -1 /usr/local/libexec/sigmond/decoders/${_d%%:*}/.provenance" 2>/dev/null \
              | grep -oE '\b[0-9a-f]{40}\b' | head -1)"
        [ -n "$_p" ] && echo "native_provenance_${_d#*:}: $_p"
    done
} > native-built.lines.new
if [ "$(grep -c '^native_built_' native-built.lines.new)" -eq 3 ] \
   && [ "$(grep -c '^native_provenance_' native-built.lines.new)" -eq 2 ]; then
    { echo "native_built_capture: ok"; cat native-built.lines.new; } > native-built.txt.new
    say "native build records captured: $(wc -l < native-built.lines.new) line(s)"
else
    { echo "native_built_capture: failed"; cat native-built.lines.new; } > native-built.txt.new
    say "WARNING: native build records incomplete ($(wc -l < native-built.lines.new) of 5 lines) -- bless gate 9 will refuse this image"
fi
rm -f native-built.lines.new

say "shutting down VM (halt, not reboot — no machine-id now)"
$SSH "sudo shutdown -h now" 2>/dev/null
for i in $(seq 1 24); do pgrep -f "name goldenv3" >/dev/null || break; sleep 5; done
pgrep -f "name goldenv3" >/dev/null && { say "force stop"; sudo pkill -f "name goldenv3"; sleep 3; }

say "compacting template"
qemu-img convert -O qcow2 -c golden-v3.qcow2 sigmond-decoder-template-v3.qcow2.new \
    || { say "FATAL: qemu-img convert failed — template NOT replaced"; rm -f sigmond-decoder-template-v3.qcow2.new golden-v3-revs.txt.new golden-v3-sigmond-commit.txt.new manifest-raw.txt.new native-built.txt.new; exit 1; }
mv -f sigmond-decoder-template-v3.qcow2.new sigmond-decoder-template-v3.qcow2
mv -f golden-v3-revs.txt.new golden-v3-revs.txt
mv -f golden-v3-sigmond-commit.txt.new golden-v3-sigmond-commit.txt
# The manifest travels with its template: a capture that failed leaves NO
# manifest (the USB build then refuses), never the previous build's.
if [ -f manifest-raw.txt.new ]; then mv -f manifest-raw.txt.new manifest-raw.txt; else rm -f manifest-raw.txt; fi
if [ -f native-built.txt.new ]; then mv -f native-built.txt.new native-built.txt; else rm -f native-built.txt; fi
ls -la sigmond-decoder-template-v3.qcow2
say "GOLDEN VM BUILD COMPLETE"
