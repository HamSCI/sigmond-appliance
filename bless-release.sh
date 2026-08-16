#!/bin/bash
# bless-release.sh — the executable release gate for sigmond-appliance.
#
# "Verified" has meant different things at different times on this fleet: a
# fix once shipped "verified" while the venv it lived in was stale; a binary
# swap was "verified" against a file that was not the one running. This
# script is what makes rung 3 of the release ladder (built -> tested ->
# BLESSED -> rolled) refuse to happen without evidence.
#
# It refuses to cut a GitHub Release unless ALL of the following hold,
# reported individually so an operator can see exactly which one stopped it:
#
#   0. the version is a real release version (no -dev, no +)
#   1. the tag exists and points at a commit reachable from origin/main
#   2. the working tree is clean
#   3. the image and its .sha256 exist and the checksum verifies
#   4. the manifest exists and contains a components block
#   5. test evidence exists and records a PASS for THIS exact image
#   6. no Release already exists for this tag
#
# Dry-run by default, matching smd update's contract on this fleet.
# --apply is required to create anything, and even then only after every
# gate above has passed.
#
# Usage: bless-release.sh <version> [--apply]
#
# Env overrides (used by the verification suite to point at scratch
# fixtures instead of the real rig -- never required for normal use):
#   APPLIANCE_REPO  sigmond-appliance checkout (default: $HOME/appliance/repos/sigmond-appliance)
#   RIG_DIR         build/test staging dir: images, .sha256, .manifest.txt,
#                    test-v3.log (default: $HOME/appliance/v3)
#   GH_REPO_SLUG    GitHub repo slug (default: HamSCI/sigmond-appliance)
set -u

say(){ echo "[bless $(date '+%T')] $*"; }

REPO="${APPLIANCE_REPO:-$HOME/appliance/repos/sigmond-appliance}"
RIG_DIR="${RIG_DIR:-$HOME/appliance/v3}"
GH_REPO="${GH_REPO_SLUG:-HamSCI/sigmond-appliance}"
TESTLOG="$RIG_DIR/test-v3.log"

APPLY=0
VERSION=""
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        -*) echo "unrecognized argument: $a" >&2; exit 2 ;;
        *)
            [ -z "$VERSION" ] || { echo "unexpected extra argument: $a" >&2; exit 2; }
            VERSION="$a"
            ;;
    esac
done
[ -n "$VERSION" ] || { echo "usage: bless-release.sh <version> [--apply]" >&2; exit 2; }

GATE_NAMES=()
GATE_RESULTS=()
GATE_DETAIL=()
FAILED=0
gate_pass(){ GATE_NAMES+=("$1"); GATE_RESULTS+=("PASS"); GATE_DETAIL+=("$2"); }
gate_fail(){ GATE_NAMES+=("$1"); GATE_RESULTS+=("FAIL"); GATE_DETAIL+=("$2"); FAILED=1; }

# ---- Gate 0: the version is a real release version -------------------------
# build-usb-v3.sh --dev stamps v0.0-dev+<sha>, which PASSES the build's own
# v[0-9]* format check (the glob only demands "v" + a digit). This gate is
# the only thing standing between a development image and a blessed release.
case "$VERSION" in
    *-dev*|*+*)
        gate_fail "0 (real release version)" \
            "'$VERSION' contains -dev or + -- this is a --dev build stamp (build-usb-v3.sh's v0.0-dev+<sha>), which passes the build's own v[0-9]* format check but must never be blessed"
        ;;
    v[0-9]*)
        gate_pass "0 (real release version)" "$VERSION"
        ;;
    *)
        gate_fail "0 (real release version)" \
            "'$VERSION' does not look like a release version (expected v<N>...)"
        ;;
esac

# ---- Gate 1: tag exists, points at a commit reachable from origin/main -----
TAG_COMMIT=""
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    gate_fail "1 (tag reachable from origin/main)" "not a git checkout: $REPO"
else
    FETCH_ERR="$(mktemp)"
    if ! git -C "$REPO" fetch origin --quiet 2>"$FETCH_ERR"; then
        say "WARN: git fetch origin failed in $REPO ($(cat "$FETCH_ERR")) -- using cached origin/main"
    fi
    rm -f "$FETCH_ERR"
    TAG_COMMIT="$(git -C "$REPO" rev-parse -q --verify "refs/tags/${VERSION}^{commit}" 2>/dev/null || true)"
    if [ -z "$TAG_COMMIT" ]; then
        gate_fail "1 (tag reachable from origin/main)" "tag '$VERSION' does not exist in $REPO"
    elif ! git -C "$REPO" merge-base --is-ancestor "$TAG_COMMIT" origin/main 2>/dev/null; then
        gate_fail "1 (tag reachable from origin/main)" "tag '$VERSION' ($TAG_COMMIT) is not reachable from origin/main"
    else
        gate_pass "1 (tag reachable from origin/main)" "$VERSION -> $TAG_COMMIT"
    fi
fi

# ---- Gate 2: working tree clean --------------------------------------------
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    gate_fail "2 (clean working tree)" "not a git checkout: $REPO"
else
    DIRTY="$(git -C "$REPO" status --porcelain 2>&1)"
    RC=$?
    if [ $RC -ne 0 ]; then
        gate_fail "2 (clean working tree)" "git status failed in $REPO: $DIRTY"
    elif [ -n "$DIRTY" ]; then
        gate_fail "2 (clean working tree)" "$REPO has uncommitted changes: $(printf '%s' "$DIRTY" | tr '\n' ';')"
    else
        gate_pass "2 (clean working tree)" "$REPO clean"
    fi
fi

# ---- Gate 3: image + .sha256 exist, checksum verifies ---------------------
IMG=""
IMGBASE=""
SHAFILE=""
IMG_MATCHES=()
if [ -d "$RIG_DIR" ]; then
    for f in "$RIG_DIR"/sigmond-appliance-"${VERSION}"-*.img; do
        [ -e "$f" ] && IMG_MATCHES+=("$f")
    done
fi
if [ ${#IMG_MATCHES[@]} -eq 0 ]; then
    gate_fail "3 (image + sha256 verified)" \
        "no image matching sigmond-appliance-${VERSION}-*.img in $RIG_DIR"
elif [ ${#IMG_MATCHES[@]} -gt 1 ]; then
    gate_fail "3 (image + sha256 verified)" \
        "multiple images match sigmond-appliance-${VERSION}-*.img in $RIG_DIR: $(printf '%s ' "${IMG_MATCHES[@]##*/}")"
else
    IMG="${IMG_MATCHES[0]}"
    IMGBASE="$(basename "$IMG")"
    SHAFILE="${IMG%.img}.sha256"
    if [ ! -f "$SHAFILE" ]; then
        gate_fail "3 (image + sha256 verified)" "no .sha256 for $IMGBASE (expected $(basename "$SHAFILE"))"
    else
        SHA_OUT="$(cd "$RIG_DIR" && sha256sum -c "$(basename "$SHAFILE")" 2>&1)"
        SHA_RC=$?
        if [ $SHA_RC -eq 0 ]; then
            gate_pass "3 (image + sha256 verified)" "$IMGBASE checksum OK"
        else
            gate_fail "3 (image + sha256 verified)" "checksum verification failed for $IMGBASE: $SHA_OUT"
            IMG=""; IMGBASE=""  # do not let a bad-checksum image feed gates 4/5
        fi
    fi
fi

# ---- Gate 4: manifest exists and contains a components block --------------
MANIFEST=""
if [ -n "$IMG" ]; then
    MANIFEST="${IMG%.img}.manifest.txt"
    MANIFESTBASE="$(basename "$MANIFEST")"
    if [ ! -f "$MANIFEST" ]; then
        gate_fail "4 (manifest has components block)" "manifest missing: $MANIFESTBASE"
        MANIFEST=""
    elif ! grep -qi '^components' "$MANIFEST"; then
        gate_fail "4 (manifest has components block)" "$MANIFESTBASE has no components block"
        MANIFEST=""
    else
        NLINES=$(grep -c '^    [A-Za-z]' "$MANIFEST")
        gate_pass "4 (manifest has components block)" "$MANIFESTBASE ($NLINES component lines)"
    fi
else
    gate_fail "4 (manifest has components block)" "cannot check -- no image resolved (see gate 3)"
fi

# ---- Gate 5: test evidence records a PASS for THIS exact image ------------
# test-nested-v3.sh appends to $TESTLOG across many builds: each invocation
# starts with "USB image under test: <filename>" and (on a full run) ends
# with "PHASE D PASS -- NESTED TEST COMPLETE". The log is append-only and
# currently holds many runs of many images, some of which failed and were
# re-run. A bare `grep PASS` over the whole log would happily match a PASS
# that belongs to a completely different image.
#
# Approach: find the LAST line naming this exact bare filename (an exact
# string match against the text after "USB image under test: ", not a
# substring match -- this also means a run logged under an accidentally
# path-prefixed name, e.g. "/srv/build/v3/sigmond-appliance-...img", does
# NOT count as evidence for the bare-named image gate 3 resolved). Bound
# that run from its marker line to the next "USB image under test:" line
# (or EOF), and require the PHASE D marker inside that bounded block.
# Using the LAST such block (not "any" block) means a stale PASS from an
# earlier attempt of the same image does not paper over a later regression.
#
# This is airtight against the "different image" trap the task called out,
# and against stale/earlier passes of the same image. It is NOT airtight
# against: (a) a hand-edited log, (b) two blocks for the same image whose
# timestamps collide across a log that was concatenated out of order, or
# (c) a marker line with extra trailing text after the filename (treated as
# a non-match -- a false negative, never a false positive). See the report
# for the full discussion.
if [ -n "$IMG" ]; then
    if [ ! -f "$TESTLOG" ]; then
        gate_fail "5 (test evidence: PHASE D PASS)" "no test log at $TESTLOG"
    else
        LASTLINE=0
        LN=0
        while IFS= read -r line; do
            LN=$((LN+1))
            case "$line" in
                *"USB image under test: "*)
                    marker="${line#*USB image under test: }"
                    [ "$marker" = "$IMGBASE" ] && LASTLINE=$LN
                    ;;
            esac
        done < "$TESTLOG"
        if [ "$LASTLINE" -eq 0 ]; then
            gate_fail "5 (test evidence: PHASE D PASS)" "no test run found for $IMGBASE in $TESTLOG"
        else
            TOTAL=$(wc -l < "$TESTLOG")
            NEXTLINE=$TOTAL
            LN=0
            while IFS= read -r line; do
                LN=$((LN+1))
                if [ "$LN" -gt "$LASTLINE" ]; then
                    case "$line" in
                        *"USB image under test: "*) NEXTLINE=$((LN-1)); break ;;
                    esac
                fi
            done < "$TESTLOG"
            BLOCK="$(sed -n "${LASTLINE},${NEXTLINE}p" "$TESTLOG")"
            if printf '%s\n' "$BLOCK" | grep -qF 'PHASE D PASS'; then
                gate_pass "5 (test evidence: PHASE D PASS)" "$IMGBASE: log lines $LASTLINE-$NEXTLINE"
            else
                gate_fail "5 (test evidence: PHASE D PASS)" \
                    "$IMGBASE: latest test run (log lines $LASTLINE-$NEXTLINE) did not reach PHASE D PASS"
            fi
        fi
    fi
else
    gate_fail "5 (test evidence: PHASE D PASS)" "cannot check -- no image resolved (see gate 3)"
fi

# ---- Gate 6: no Release already exists for this tag ------------------------
GH_OUT="$(gh release view "$VERSION" --repo "$GH_REPO" 2>&1)"
GH_RC=$?
if [ $GH_RC -eq 0 ]; then
    gate_fail "6 (no existing Release)" "a Release already exists for $VERSION on $GH_REPO"
elif printf '%s' "$GH_OUT" | grep -qi 'release not found'; then
    gate_pass "6 (no existing Release)" "no Release for $VERSION on $GH_REPO"
else
    gate_fail "6 (no existing Release)" "could not verify -- gh release view failed: $GH_OUT"
fi

# ---- report -----------------------------------------------------------------
say "=== bless-release.sh $VERSION ($([ $APPLY -eq 1 ] && echo apply || echo dry-run)) ==="
i=0
while [ $i -lt ${#GATE_NAMES[@]} ]; do
    printf '  [gate %-40s %-4s %s\n' "${GATE_NAMES[$i]}]" "${GATE_RESULTS[$i]}" "${GATE_DETAIL[$i]}"
    i=$((i+1))
done

if [ $FAILED -ne 0 ]; then
    say "BLOCKED: one or more gates failed -- refusing to bless $VERSION"
    exit 1
fi
say "ALL GATES PASS -- $VERSION is ready to bless"

if [ $APPLY -eq 0 ]; then
    say "DRY RUN -- would create Release $VERSION on $GH_REPO attaching:"
    say "  $(basename "$MANIFEST")"
    say "  $(basename "$SHAFILE")"
    say "Re-run with --apply to publish. Creating a public Release is outward-facing and requires explicit human authorization."
    exit 0
fi

# ---- --apply: build release notes, self-check for leakage, publish --------
# HamSCI/sigmond-appliance is PUBLIC. Release notes reference the image by
# filename and sha256 only -- never a host, path, IP, or username.
PREV_TAG="$(git -C "$REPO" tag --merged origin/main --sort=-v:refname 2>/dev/null \
    | grep -vE -- '-dev|\+' \
    | awk -v cur="$VERSION" 'found{print; exit} $0==cur{found=1}')"
if [ -n "$PREV_TAG" ]; then
    CHANGELOG="$(git -C "$REPO" log --oneline "${PREV_TAG}..${VERSION}")"
else
    CHANGELOG="(no previous tag -- first release)"
fi

NOTES="$(mktemp)"
{
    echo "## sigmond-appliance $VERSION"
    echo
    echo "- Version: $VERSION"
    echo "- Appliance commit: $TAG_COMMIT"
    echo "- Image: $IMGBASE"
    echo "- SHA-256: $(cut -d' ' -f1 < "$SHAFILE")"
    echo "- Test verdict: PASS (PHASE D PASS -- NESTED TEST COMPLETE, test-nested-v3.sh)"
    echo
    echo "### Changelog since ${PREV_TAG:-(none)}"
    echo '```'
    echo "$CHANGELOG"
    echo '```'
} > "$NOTES"

# Leakage self-check: hostnames, IPs, host:path/absolute-path strings,
# usernames. Fails closed -- refuses to publish rather than guess.
LEAK_PATTERN='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|/root/|/home/[A-Za-z]+|~/|\broot@|\b(wd30|b3|b4|bee1|bee2|gw2|dasi[0-9]*|b4-prox|hamsci@|sigmond@|mijahauan|michael\.j\.hauan)\b'
LEAK_HITS="$(grep -inE "$LEAK_PATTERN" "$NOTES" || true)"
if [ -n "$LEAK_HITS" ]; then
    say "FATAL: release notes leakage check failed -- refusing to publish. Offending lines:"
    printf '%s\n' "$LEAK_HITS"
    rm -f "$NOTES"
    exit 1
fi

say "publishing Release $VERSION on $GH_REPO"
gh release create "$VERSION" --repo "$GH_REPO" \
    --title "sigmond-appliance $VERSION" --notes-file "$NOTES" \
    "$MANIFEST" "$SHAFILE"
RC=$?
rm -f "$NOTES"
exit $RC
