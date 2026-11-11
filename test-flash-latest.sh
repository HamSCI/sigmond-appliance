#!/bin/bash
# test-flash-latest.sh — sigmond-flash-latest.sh must pick only a USB stick,
# refuse anything else, and never hang on its arguments.
#
# Runs the Linux path against PATH-shimmed fakes: curl serves a one-image
# folder listing, lsblk/findmnt describe a fake set of disks, and dd/sudo
# record that they were called.  DRY_RUN=1 throughout.  No root, no network,
# no real disk is ever read or written.
set -u
cd "$(dirname "$0")" || exit 1
REPO=$PWD
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); printf '  ok    %s\n' "$*"; }
bad(){ FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }

bash -n sigmond-flash-latest.sh || { echo "FATAL: sigmond-flash-latest.sh does not parse"; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "SKIP: the fakes model Linux lsblk"; exit 0; }

# ── the fakes ──────────────────────────────────────────────────────────────
BIN=$W/bin IMGS=$W/images; mkdir -p "$BIN" "$IMGS"
STEM=sigmond-appliance-v9.99-20260101-release
printf 'x' > "$IMGS/$STEM.img"
SHA=$(sha256sum "$IMGS/$STEM.img" | awk '{print $1}')
# A newer, untested build that only pending/ holds.
PSTEM=sigmond-appliance-v9.100-20260102-release
printf 'y' > "$IMGS/$PSTEM.img"
PSHA=$(sha256sum "$IMGS/$PSTEM.img" | awk '{print $1}')

cat > "$BIN/curl" <<EOF
#!/bin/bash
[ -n "\${CURLLOG:-}" ] && echo "curl \$*" >> "\$CURLLOG"
case "\$*" in
  *embeddedfolderview*id=PENDID*)
    printf '%s' '<div class="flip-entry" id="entry-PIMGID"><div class="flip-entry-title">$PSTEM.img</div></div>'
    printf '%s' '<div class="flip-entry" id="entry-PSHAID"><div class="flip-entry-title">$PSTEM.sha256</div></div>' ;;
  *embeddedfolderview*)
    printf '%s' '<div class="flip-entry" id="entry-PENDID"><div class="flip-entry-title">pending</div></div>'
    printf '%s' '<div class="flip-entry" id="entry-IMGID"><div class="flip-entry-title">$STEM.img</div></div>'
    printf '%s' '<div class="flip-entry" id="entry-SHAID"><div class="flip-entry-title">$STEM.sha256</div></div>' ;;
  *id=SHAID*) echo "$SHA  $STEM.img" ;;
  *id=PSHAID*) echo "$PSHA  $PSTEM.img" ;;
  *) exit 22 ;;
esac
EOF

# Disk table, one per line: name type tran rm size parent ("-" = none).
# lsblk -s walks parent links up to the disk; -d prints the device itself.
cat > "$BIN/lsblk" <<'EOF'
#!/bin/bash
flags="" cols="" dev="" want_cols=0
for a in "$@"; do
    if [ "$want_cols" = 1 ]; then cols=$a; want_cols=0; continue; fi
    case "$a" in
        -*) flags="$flags${a#-}"; case "$a" in *o) want_cols=1 ;; esac ;;
        *)  dev=${a#/dev/} ;;
    esac
done
row(){ awk -v n="$1" '$1==n' "$FAKE_DISKS"; }
field(){   # field <row> <column>
    set -- $1 "$2"
    case "$7" in
        NAME) echo "/dev/$1" ;; TYPE) echo "$2" ;; RM) echo "$4" ;; SIZE) echo "$5" ;;
        TRAN) [ "$3" = - ] || echo "$3" ;; *) echo "Fake Model" ;;
    esac
}
if [ -n "$dev" ] && [ -z "$(row "$dev")" ]; then
    echo "lsblk: /dev/$dev: not a block device" >&2; exit 32
fi
case "$flags" in
  *s*)   # inverse: the device, then its ancestors
    n=$dev
    while [ -n "$n" ] && [ "$n" != - ]; do
        r=$(row "$n"); echo "/dev/$n $(field "$r" TYPE)"
        n=$(set -- $r; echo "$6")
    done ;;
  *d*)
    if [ -z "$dev" ]; then
        awk '$6=="-"{print "/dev/"$1}' "$FAKE_DISKS"
    else
        r=$(row "$dev"); out=""
        for c in ${cols//,/ }; do out="$out${out:+ }$(field "$r" "$c")"; done
        echo "$out"
    fi ;;
  *)     # the device and its children (no mountpoints in these fakes)
    echo "$dev"; awk -v p="$dev" '$6==p{print $1}' "$FAKE_DISKS" ;;
esac
EOF

cat > "$BIN/findmnt" <<'EOF'
#!/bin/bash
[ "${!#}" = / ] && { echo "$FAKE_ROOT"; exit 0; }
exit 1
EOF
printf '#!/bin/bash\necho "dd $*" >> "$CALLS"; exit 0\n'   > "$BIN/dd"
printf '#!/bin/bash\necho "sudo $*" >> "$CALLS"; exit 1\n' > "$BIN/sudo"
chmod +x "$BIN"/*

# run <disk table> <root source> <args...> — sets OUT and RC.
run(){
    printf '%s\n' "$1" > "$W/disks"; local root=$2; shift 2
    : > "$W/calls"; : > "$W/curl"
    OUT=$(FAKE_DISKS="$W/disks" FAKE_ROOT="$root" CALLS="$W/calls" CURLLOG="$W/curl" \
          PATH="$BIN:$PATH" SIGMOND_IMAGE_DIR="${TEST_IMGS:-$IMGS}" SIGMOND_NO_UPDATE=1 DRY_RUN="${TEST_DRY:-1}" \
          timeout 20 bash "$REPO/sigmond-flash-latest.sh" "$@" </dev/null 2>&1)
    RC=$?
}
# expect <label> <rc> <regex>
expect(){
    if [ "$RC" = "$2" ] && printf '%s' "$OUT" | grep -qE "$3"; then ok "$1"
    else bad "$1 (rc=$RC, wanted $2 and /$3/)"; printf '%s\n' "$OUT" | sed 's/^/          | /'; fi
    if [ -s "$W/calls" ]; then bad "$1: dd or sudo was called"; sed 's/^/          | /' "$W/calls"; fi
}

SYS='sda disk sata 0 500107862016 -
sda1 part - 0 500000000000 sda'
STICK='sdb disk usb 1 32000000000 -
sdb1 part - 0 31000000000 sdb'
STICK2='sdc disk usb 1 64000000000 -'
BIGUSB='sdd disk usb 1 2000000000000 -'
USBSSD='sde disk usb 0 500000000000 -'

echo "arguments"
run "$SYS" /dev/sda1 --device;            expect "--device with no value is an error, not a hang" 1 'needs a value'
run "$SYS" /dev/sda1 --version;           expect "--version with no value is an error, not a hang" 1 'needs a value'
run "$SYS" /dev/sda1 --device --list;     expect "--device followed by an option is an error" 1 'needs a value'

echo "named --device"
run "$SYS
$STICK" /dev/sda1 --device /dev/sdb1;     expect "a partition is refused" 1 'not a whole disk'
run "$SYS
$STICK" /dev/sda1 --device /dev/sda;      expect "a SATA disk is refused" 1 'not on USB'
run "$SYS
$USBSSD" /dev/sda1 --device /dev/sde;     expect "a non-removable USB disk is refused" 1 'not removable'
run "$SYS" /dev/sda1 --device /dev/nope;  expect "a missing device is refused" 1 'not a block device'
run "$SYS
$STICK" /dev/sda1 --device /dev/sdb;      expect "a USB stick passes every check" 0 'every check passed'
run "sdb disk usb 1 32000000000 -
sdb2 part - 0 31000000000 sdb
mapper/vg-root lvm - 0 30000000000 sdb2" /dev/mapper/vg-root --device /dev/sdb
                                          expect "a stick under an LVM root is refused" 1 'CARRIES THE RUNNING SYSTEM'

echo "automatic pick"
run "$SYS" /dev/sda1;                     expect "no stick exits 2" 2 'NO USB STICK FOUND'
run "$SYS
$BIGUSB" /dev/sda1;                       expect "a 2 TB USB disk is over the cap: no stick, exit 2" 2 'over the 1024 GiB cap'
run "$SYS
$STICK
$BIGUSB" /dev/sda1;                       expect "the stick is picked past a 2 TB USB disk" 0 'found USB stick: /dev/sdb'
run "$SYS
$STICK
$STICK2" /dev/sda1;                       expect "two sticks are refused" 1 'exactly one USB stick.*found 2'
run "$SYS
$USBSSD" /dev/sda1;                       expect "a non-removable USB disk is never auto-picked" 2 'NO USB STICK FOUND'

echo "questions before the download"
# The download can take an hour: the stick must be found, and the erase
# question asked, before any byte of the image is fetched (rob, 2026-11-11).
mkdir -p "$W/empty"
fetched(){ grep -q 'id=IMGID' "$W/curl"; }
TEST_IMGS=$W/empty run "$SYS" /dev/sda1;  expect "no stick stops before the download" 2 'NO USB STICK FOUND'
fetched && bad "no stick: the image was fetched anyway" || ok "no stick: the image was never fetched"
TEST_IMGS=$W/empty TEST_DRY=0 run "$SYS
$STICK" /dev/sda1
expect "the erase question comes before the download" 1 'no terminal to confirm.*--yes'
grep -q -- '-o .*\.part' "$W/curl" && bad "the image download started before the erase question" \
    || ok "nothing was downloaded before the erase question"
run "$SYS
$STICK" /dev/sda1 --yes;                  expect "--yes is accepted" 0 'every check passed'

echo "--pending (untested builds from pending/)"
run "$SYS" /dev/sda1 --list;              expect "--list alone never shows a pending build" 0 'v9\.99 20260101'
printf '%s' "$OUT" | grep -q 'v9\.100' && bad "--list alone showed the pending v9.100" || ok "--list alone leaves pending/ out"
grep -q 'id=PENDID' "$W/curl" && bad "pending/ was read without --pending" || ok "pending/ is not read without --pending"
run "$SYS" /dev/sda1 --pending --list;    expect "--pending --list marks the pending build" 0 'v9\.100 20260102  PENDING \(untested\)'
run "$SYS
$STICK" /dev/sda1 --pending;              expect "--pending picks the newest build, the pending one" 0 'selected: '"$PSTEM"'\.img'
printf '%s' "$OUT" | grep -q 'PENDING: an untested build' && ok "--pending says the pick is untested" || bad "--pending did not say the pick is untested"
run "$SYS
$STICK" /dev/sda1;                        expect "without --pending the newest published build is picked" 0 'selected: '"$STEM"'\.img'
run "$SYS
$STICK" /dev/sda1 --version v9.100;       expect "--version of a pending build without --pending says to add it" 1 'not published.*add --pending'
run "$SYS
$STICK" /dev/sda1 --pending --version v9.99
                                          expect "--pending --version can still pick a published build, unmarked" 0 'selected: '"$STEM"'\.img'
printf '%s' "$OUT" | grep -q 'PENDING:' && bad "a published pick was marked PENDING" || ok "a published pick is not marked PENDING"

echo "sudo policy"
if grep -q 'NOPASSWD\|sudoers' sigmond-flash-latest.sh; then bad "the flasher mentions NOPASSWD/sudoers"
else ok "the flasher never touches the sudo policy"; fi

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
