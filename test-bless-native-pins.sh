#!/bin/bash
# test-bless-native-pins.sh -- bless-release.sh gate 9: an image's native
# sources come from the release's pins.
#
# Michael, 2026-11-20: "Any pinning or version specifications should reside in
# the base repo and not vary per station."  Until v3.94 an image built at
# newest main shipped /etc/sigmond/component-pins.toml, a per-station file that
# won over sigmond's constants: SIGMA, KFS-MAIN and AC1SN held ubersdr_wsprd at
# 8719788 that way while sigmond pinned 5eeeb53.  sigmond no longer reads the
# file, so gate 9 refuses an image whose onion, wsjtx or ubersdr_wsprd checkout,
# or recorded build (native_built_* preamble lines), differs from bin/smd's
# constants at the manifest's sigmond commit.
#
# Hermetic: a scratch sigmond repo, a scratch rig dir holding an image, its
# .sha256 and manifest, and a stub gh.  Other gates fail in this fixture (no
# tag, no instructions); each scene reads only gate 9's row.
#
#   usage: ./test-bless-native-pins.sh [path/to/bless-release.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BLESS="${1:-$HERE/bless-release.sh}"
[ -f "$BLESS" ] || { echo "FATAL: no bless-release.sh at $BLESS"; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=scratch GIT_AUTHOR_EMAIL=scratch@example.invalid
export GIT_COMMITTER_NAME=scratch GIT_COMMITTER_EMAIL=scratch@example.invalid

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing: $3 | in: ${2:0:400}" ;; esac; }

mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'EOF'
#!/bin/bash
echo "release not found" >&2; exit 1
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"

ONION=124c28c8f74fa73ffa2cc5a3b0273633563be366
WSJTX=ccdfaf3c1c109010d15399674ce278167cfde848
UBER=5eeeb53576d8d3f9c73de8b8fa9a3d9a39175395
OLD=8719788cccccccccccccccccccccccccccccccc1

# A scratch sigmond whose bin/smd holds the release's constants.
SIG="$T/sigmond"
mkdir -p "$SIG/bin"
git -C "$SIG" init -q
cat > "$SIG/bin/smd" <<EOF
#!/usr/bin/env python3
_ONION_COMMIT = '$ONION'   # master
_WSJTX_COMMIT = '$WSJTX'   # v3.0.2 GA
_UBERSDR_COMMIT = '$UBER'   # madpsy main
EOF
git -C "$SIG" add bin/smd
git -C "$SIG" commit -qm "pins"
SIGSHA="$(git -C "$SIG" rev-parse --short=8 HEAD)"

VERSION=v3.94
scene() { # scene <ubersdr row> <preamble lines> [sigmond row] [row to omit]
    local rig="$T/rig-$RANDOM"
    mkdir -p "$rig"
    local stem="sigmond-appliance-$VERSION-20261120-release"
    echo "image bytes $RANDOM" > "$rig/$stem.img"
    (cd "$rig" && sha256sum "$stem.img" > "$stem.sha256")
    {
        echo "image_version: $VERSION"
        echo "appliance_tag: $VERSION"
        echo "built_utc: 2026-11-20T00:00:00+00:00"
        printf '%b' "$2"
        echo
        echo "components (live):"
        {   echo "    callhash         adc9d9d"
            echo "    onion            ${ONION:0:7}"
            echo "    sigmond          ${3:-$SIGSHA}"
            echo "    ubersdr_wsprd    $1"
            echo "    wsjtx            ${WSJTX:0:9}"
        } | grep -v "^    ${4:-NOTHING} "
        echo
        echo "what each is at (newest first):"
        echo "    2026-11-17  ubersdr_wsprd     ${1}  build.sh"
    } > "$rig/$stem.manifest.txt"
    OUT="$(APPLIANCE_REPO="$T/no-appliance" RIG_DIR="$rig" SIGMOND_REPO="$SIG" \
           GH_REPO_SLUG=scratch/none bash "$BLESS" "$VERSION" 2>&1)"
    ROW="$(printf '%s\n' "$OUT" | grep -F '[gate 9 (native pins come from the release)]')"
}

PROV="native_provenance_wsjtx: $WSJTX\nnative_provenance_ubersdr_wsprd: $UBER\n"
BUILT_ONLY="native_built_onion: $ONION\nnative_built_wsjtx: $WSJTX\nnative_built_ubersdr_wsprd: $UBER\n"
BUILT="native_built_capture: ok\n$BUILT_ONLY$PROV"

echo "scene 1: checkouts and builds at sigmond's pins"
scene "${UBER:0:7}" "$BUILT"
has "gate 9 passes" "$ROW" "PASS"
has "it counts the build records and provenance" "$ROW" "3 build record(s) and 2 decoder provenance(s) match sigmond $SIGSHA"

echo "scene 2: the image's ubersdr_wsprd checkout trails the pin (SIGMA, 11-20)"
scene "${OLD:0:7}" "$BUILT"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the checkout and the pin" "$ROW" "ubersdr_wsprd checkout 8719788, pin 5eeeb5357"
has "it says how to fix it" "$ROW" "write the commits into bin/smd's constants in sigmond"
has "the bless is blocked" "$OUT" "BLOCKED"

echo "scene 3: the checkout sits at the pin, the build came from elsewhere"
scene "${UBER:0:7}" "native_built_capture: ok\nnative_built_onion: $ONION\nnative_built_wsjtx: $WSJTX\nnative_built_ubersdr_wsprd: $OLD\n$PROV"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the built commit" "$ROW" "ubersdr_wsprd built from 8719788cc, pin 5eeeb5357"

echo "scene 4: a newest-main candidate whose commits never reached sigmond"
scene "${UBER:0:7}" "native_built_capture: ok\nnative_built_onion: 9999999000000000000000000000000000000000\nnative_built_wsjtx: $WSJTX\nnative_built_ubersdr_wsprd: $UBER\n$PROV"
has "gate 9 fails on onion" "$ROW" "onion built from 999999900, pin 124c28c8f"

echo "scene 5: a manifest from before the build-record capture (no marker, no lines)"
scene "${UBER:0:7}" ""
has "gate 9 warns" "$ROW" "WARN"
has "it says the builds are unverified" "$ROW" "the built binaries are NOT verified"

echo "scene 6: the manifest names a sigmond commit the repo lacks"
scene "${UBER:0:7}" "$BUILT" "0123abcd"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the unreadable commit" "$ROW" "cannot read bin/smd at sigmond 0123abcd"

echo "scene 7: the build-record capture failed"
scene "${UBER:0:7}" "native_built_capture: failed\n"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the failed capture" "$ROW" "the build-record capture failed"

echo "scene 8: only some build records (no marker)"
scene "${UBER:0:7}" "native_built_onion: $ONION\nnative_built_ubersdr_wsprd: $UBER\n"
has "gate 9 fails" "$ROW" "FAIL"
has "it counts the lines" "$ROW" "only 2 of 3 native_built_ lines"

echo "scene 9: a native checkout row is missing"
scene "${UBER:0:7}" "$BUILT" "" wsjtx
has "gate 9 fails" "$ROW" "FAIL"
has "it names the missing row" "$ROW" "no wsjtx checkout row"

echo "scene 10: the decoder's .provenance names another commit"
scene "${UBER:0:7}" "native_built_capture: ok\n$BUILT_ONLY""native_provenance_wsjtx: $WSJTX\nnative_provenance_ubersdr_wsprd: $OLD\n"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the provenance" "$ROW" "ubersdr_wsprd decoder provenance 8719788cc, pin 5eeeb5357"

echo "scene 11: a capture marked ok without the provenance lines"
scene "${UBER:0:7}" "native_built_capture: ok\n$BUILT_ONLY"
has "gate 9 fails" "$ROW" "FAIL"
has "it names the missing provenance" "$ROW" "no native_provenance_wsjtx line"

echo
if [ "$FAIL" -eq 0 ]; then echo "PASS: $PASS checks"; exit 0; fi
echo "FAILED: $FAIL of $((PASS+FAIL)) checks"; exit 1
