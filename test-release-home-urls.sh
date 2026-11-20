#!/usr/bin/env bash
# test-release-home-urls.sh -- the release moved to sigmond and the repo
# is named sigmond-proxmox.  Checks the tracked files, no network.
#   - no live HamSCI/sigmond-appliance URL, no repos/sigmond-appliance path
#   - bless-release.sh and its tests are gone (they live in sigmond release/)
#   - docs/RELEASE.md and CHANGELOG.md point at HamSCI/sigmond
# The flasher curl lines (INSTALL.md, docs/install-page.html) must keep the
# old name; they fetch at run time and the new name 404s before the rename.
# Exempt: docs/superpowers/ (history), this test, and the two files that
# name the rig's local checkout directory, which is renamed only in the
# operator steps (build-usb-v3.sh REPO fallback, test-release-home-lib.sh).
cd "$(dirname "$0")" || exit 1
PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

files=$(git ls-files | grep -v -e '^docs/superpowers/' \
    -e '^test-release-home-urls\.sh$' -e '^build-usb-v3\.sh$' \
    -e '^test-release-home-lib\.sh$')
# shellcheck disable=SC2086
# Run-time download lines keep the old name until the mirror ends.
FETCH='raw.githubusercontent.com/HamSCI/sigmond-appliance/main/sigmond-flash-latest.sh'
hits=$(grep -In -e 'HamSCI/sigmond-appliance' -e 'repos/sigmond-appliance' $files | grep -vF "$FETCH")
if [ -z "$hits" ]; then ok "no old repo URL or path in tracked files"
else bad "old repo name still live:"; echo "$hits"; fi

# The exempt files may name the old directory, never the old URL.
if grep -In 'HamSCI/sigmond-appliance' build-usb-v3.sh test-release-home-lib.sh; then
    bad "old URL in an exempt file"; else ok "exempt files carry no old URL"; fi

for f in INSTALL.md docs/install-page.html; do
    if grep -qF "$FETCH" "$f"; then ok "$f flasher line keeps the old name"
    else bad "$f flasher line lost the old name"; fi
done
if grep -rIl 'raw.githubusercontent.com/HamSCI/sigmond-proxmox' $files; then
    bad "run-time fetch on the new name"; else ok "no fetch on the new name"; fi

for f in bless-release.sh test-bless-instructions.sh test-bless-native-pins.sh; do
    if git ls-files --error-unmatch "$f" >/dev/null 2>&1 || [ -e "$f" ]; then
        bad "$f still here"; else ok "$f gone"; fi
done

for f in docs/RELEASE.md CHANGELOG.md; do
    if grep -q 'github.com/HamSCI/sigmond/blob/main/' "$f" && ! grep -q 'HamSCI/sigmond-appliance' "$f"; then
        ok "$f names HamSCI/sigmond"; else bad "$f does not name HamSCI/sigmond"; fi
done

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
