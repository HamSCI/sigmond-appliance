#!/bin/bash
# test-release-home-lib.sh -- the image build installs and checks sigmond's
# release list (release/components.toml), not main.  Hermetic: a scratch
# sigmond repo built from the sibling checkout's lib/sigmond, no network.
#
#   bash test-release-home-lib.sh            (SIGMOND_REPO defaults to ../sigmond)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SIGMOND_REPO="${SIGMOND_REPO:-$HERE/../sigmond}"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1${2:+ -- $2}"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -d "$SIGMOND_REPO/lib/sigmond" ] || { echo "FAIL: no lib/sigmond under $SIGMOND_REPO"; exit 1; }

# ── scratch sigmond: lib/sigmond plus two commits, the second with a list ──
S="$T/sigmond"; mkdir -p "$S/lib"
cp -r "$SIGMOND_REPO/lib/sigmond" "$S/lib/"
find "$S/lib" -name __pycache__ -prune -exec rm -rf {} +
g() { git -C "$S" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
g init -q
g add lib; g commit -q -m "no list yet"
NOLIST="$(g rev-parse HEAD)"

sha() { printf '%s' "$1" | sha1sum | cut -c1-40; }
ROWS="callhash codar-sounder ft8_lib gmag-webui gpsdo-monitor hamsci-dsp hamsci-physics
hf-tec hf-timestd hfdl-recorder hs-uploader igmp-querier ka9q-python ka9q-radio ka9q-web
mag-recorder meteor-scatter onion psk-recorder sigmond-proxmox sigmond-rac station-web
superdarn-sounder ubersdr_wsprd wsjtx wspr-recorder"
mkdir -p "$S/release"
{
    echo '# sigmond release list -- fixture'
    echo 'version = "v3.94"'
    echo
    echo '[components]'
    for r in $ROWS; do echo "$r = \"$(sha "$r")\""; done
} > "$S/release/components.toml"
g add release; g commit -q -m "release list v3.94"
WITHLIST="$(g rev-parse HEAD)"
PX="$(sha sigmond-proxmox)"

# A manifest as build-usb-v3.sh writes it: preamble, then smd version's block.
manifest() {   # manifest <moved-row-or-empty>
    echo "image_version: v3.94"
    echo "appliance_commit: $PX"
    echo "appliance_tag: v3.94"
    echo
    echo "components (live):"
    echo "    sigmond              $(sha sigmond | cut -c1-7)"
    for r in $ROWS; do
        [ "$r" = sigmond-proxmox ] && continue
        if [ "$r" = "$1" ]; then echo "    $r $(sha "$r-moved" | cut -c1-7)"
        else echo "    $r $(sha "$r" | cut -c1-7)"; fi
    done
}
manifest "" > "$T/good.txt"
manifest hf-timestd > "$T/moved.txt"

# shellcheck disable=SC1091
if ! . "$HERE/release-home-lib.sh" 2>/dev/null; then
    bad "release-home-lib.sh sources" "missing or broken"
fi

# ── rh_sigmond_commit ──
R="$T/rig"; mkdir -p "$R"
echo "$WITHLIST" > "$R/golden-v3-sigmond-commit.txt"
out="$(rh_sigmond_commit "$R" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = "$WITHLIST" ] && ok "rh_sigmond_commit prints C4's commit" \
    || bad "rh_sigmond_commit on a good file" "rc=$rc out=$out"
rm -f "$R/golden-v3-sigmond-commit.txt"
rh_sigmond_commit "$R" >/dev/null 2>&1 && bad "rh_sigmond_commit on a missing file succeeds" \
    || ok "rh_sigmond_commit fails on a missing file"
echo "${WITHLIST:0:12}" > "$R/golden-v3-sigmond-commit.txt"
rh_sigmond_commit "$R" >/dev/null 2>&1 && bad "rh_sigmond_commit on a short commit succeeds" \
    || ok "rh_sigmond_commit fails on a short commit"

# ── rh_list_text / rh_version / rh_proxmox_row ──
rh_list_text "$S" "$WITHLIST" 2>/dev/null | grep -q '^version = "v3.94"' \
    && ok "rh_list_text reads the list at the commit" || bad "rh_list_text"
rh_list_text "$S" "$NOLIST" >/dev/null 2>&1 && bad "rh_list_text succeeds with no list" \
    || ok "rh_list_text fails when the commit has no list"
out="$(rh_version "$S" "$WITHLIST" 2>&1)"
[ "$out" = v3.94 ] && ok "rh_version prints v3.94" || bad "rh_version" "got: $out"
out="$(rh_proxmox_row "$S" "$WITHLIST" 2>&1)"
[ "$out" = "$PX" ] && ok "rh_proxmox_row prints the sigmond-proxmox row" || bad "rh_proxmox_row" "got: $out"

# ── rh_check_manifest ──
out="$(rh_check_manifest "$S" "$WITHLIST" "$T/good.txt" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "rh_check_manifest: 0 on a matching manifest" || bad "rh_check_manifest on a match" "rc=$rc $out"
out="$(rh_check_manifest "$S" "$WITHLIST" "$T/moved.txt" 2>&1)"; rc=$?
[ "$rc" = 1 ] && ok "rh_check_manifest: 1 on one moved row" || bad "rh_check_manifest on a moved row" "rc=$rc $out"
printf '%s\n' "$out" | grep -q '^hf-timestd:' && ok "the mismatch names hf-timestd" \
    || bad "the mismatch names the moved row" "$out"
[ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && ok "only the moved row is named" || bad "only the moved row is named" "$out"
rh_check_manifest "$S" "$NOLIST" "$T/good.txt" >/dev/null 2>&1; rc=$?
[ "$rc" != 0 ] && ok "rh_check_manifest: non-zero when the commit has no list" \
    || bad "rh_check_manifest with no list passed"

# ── the scripts ──
P="$HERE/provision-components.sh"; P1="$HERE/provision.sh"
U="$HERE/build-usb-v3.sh"; G="$HERE/build-golden-vm.sh"
grep -q 'SIGMOND_TRACK_MAIN=1' "$P" && bad "provision-components.sh still sets SIGMOND_TRACK_MAIN=1" \
    || ok "provision-components.sh drops SIGMOND_TRACK_MAIN=1"
grep -q 'smd install --yes --release-list /opt/git/sigmond/sigmond/release/components.toml' "$P" \
    && ok "provision-components.sh installs --release-list" || bad "provision-components.sh lacks --release-list"
grep -q 'checkout.*--detach.*SIGMOND_COMMIT\|checkout.*SIGMOND_COMMIT.*--detach' "$P1" \
    && ok "provision.sh checks out \$SIGMOND_COMMIT detached" || bad "provision.sh checks out \$SIGMOND_COMMIT"
grep -q 'describe --tags --exact-match' "$U" && bad "build-usb-v3.sh still reads the version from a tag" \
    || ok "build-usb-v3.sh reads no tag for the version"
grep -q 'rh_check_manifest' "$U" && ok "build-usb-v3.sh calls rh_check_manifest" || bad "build-usb-v3.sh never calls rh_check_manifest"
grep -q 'rh_proxmox_row' "$U" && ok "build-usb-v3.sh checks its own commit against the list" || bad "build-usb-v3.sh never calls rh_proxmox_row"
grep -q 'origin/main' "$U" && bad "build-usb-v3.sh still compares with origin/main" || ok "build-usb-v3.sh no longer tracks origin/main"
grep -q 'release-list --check --require-all' "$G" && ok "build-golden-vm.sh runs release-list --check --require-all" \
    || bad "build-golden-vm.sh lacks release-list --check --require-all"
grep -q 'golden-v3-sigmond-commit.txt' "$G" && ok "build-golden-vm.sh records C4" || bad "build-golden-vm.sh never writes C4"
grep -q 'GOLDEN_ALLOW_BEHIND' "$G" && bad "build-golden-vm.sh keeps the freshness block" || ok "build-golden-vm.sh freshness block replaced"
# ── build-usb-v3.sh's early gates, run for real on a scratch rig ──
# The image repo is a scratch git holding the lib; the list's sigmond-proxmox
# row names its HEAD or not.  The run stops at the missing Proxmox ISO, after
# the version and row gates, so reaching that line means the gates passed.
usb_run() {   # usb_run <px_row> [args...] -> output in $T/usb.out, rc in $usb_rc
    local row="$1"; shift
    rm -rf "$T/u"; mkdir -p "$T/u/rig/v3" "$T/u/rig/build" "$T/u/home" "$T/u/px"
    cp "$HERE/release-home-lib.sh" "$T/u/px/"
    git -C "$T/u/px" init -q
    git -C "$T/u/px" add release-home-lib.sh
    git -C "$T/u/px" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m px
    local head; head="$(git -C "$T/u/px" rev-parse HEAD)"
    [ "$row" = HEAD ] && row="$head"
    git -C "$S" checkout -q "$WITHLIST"
    sed -i "s/^sigmond-proxmox = .*/sigmond-proxmox = \"$row\"/" "$S/release/components.toml"
    g commit -q -am "list names px $row"; local c4; c4="$(g rev-parse HEAD)"
    echo "$c4" > "$T/u/rig/v3/golden-v3-sigmond-commit.txt"
    HOME="$T/u/home" APPLIANCE_RIG_ROOT="$T/u/rig" APPLIANCE_REPO="$T/u/px" SIGMOND_REPO="$S" \
        bash "$U" "$@" > "$T/usb.out" 2>&1
    usb_rc=$?
}
usb_run HEAD --no-ship
if [ "$usb_rc" != 0 ] && grep -q 'proxmox-ve_9.1-1.iso missing' "$T/usb.out" \
   && grep -q 'release list v3.94' "$T/usb.out"; then
    ok "build-usb-v3.sh: list names this HEAD -> version v3.94, gates pass"
else bad "build-usb-v3.sh with a matching row" "$(tail -3 "$T/usb.out")"; fi
usb_run "$(sha other-commit)" --no-ship
if grep -q 'names sigmond-proxmox' "$T/usb.out" && ! grep -q 'iso missing' "$T/usb.out"; then
    ok "build-usb-v3.sh refuses a HEAD the list does not name"
else bad "build-usb-v3.sh with a differing row" "$(tail -3 "$T/usb.out")"; fi
usb_run "$(sha other-commit)" --no-ship --dev
if grep -q 'stamping v0.0-dev+' "$T/usb.out" && grep -q 'iso missing' "$T/usb.out"; then
    ok "build-usb-v3.sh --dev skips the row check"
else bad "build-usb-v3.sh --dev" "$(tail -3 "$T/usb.out")"; fi

for f in "$P" "$P1" "$U" "$G" "$HERE/release-home-lib.sh"; do
    bash -n "$f" 2>/dev/null && ok "bash -n $(basename "$f")" || bad "bash -n $(basename "$f")"
done

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
