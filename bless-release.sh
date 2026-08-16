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
        # `|| [ -n "$line" ]` is needed on both loops below: plain `while
        # read -r line; do ... done` silently DROPS a final line that has
        # no trailing newline (read returns nonzero at EOF even though it
        # already populated $line, and a bare while-read treats that
        # nonzero as loop-exit before the body runs). A killed or
        # partially-flushed test-nested-v3.sh run is exactly the case
        # where the log's last line could be missing its newline -- and
        # that last line could be the PHASE D PASS marker itself. Same
        # reasoning applies to TOTAL below: `wc -l` counts newlines, not
        # lines, so it undercounts by one for the same reason; `awk
        # 'END{print NR}'` counts records instead and doesn't.
        LASTLINE=0
        LN=0
        while IFS= read -r line || [ -n "$line" ]; do
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
            TOTAL=$(awk 'END{print NR}' "$TESTLOG")
            NEXTLINE=$TOTAL
            LN=0
            while IFS= read -r line || [ -n "$line" ]; do
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

# ---- --apply: verify remote tag, build notes, self-check, confirm, publish
# HamSCI/sigmond-appliance is PUBLIC. Release notes reference the image by
# filename and sha256 only -- never a host, path, IP, or username.

# Close the gap between gate 1 (verifies the LOCAL tag's commit) and what
# `gh release create` actually does: if refs/tags/$VERSION does not exist
# on the remote, gh silently creates a lightweight tag from the CURRENT tip
# of the default branch -- not the commit gate 1 verified, and not the
# commit the notes below claim under "Appliance commit:". An operator who
# blessed a tag they forgot to push, with any commit landing on
# origin/main in between, would get a Release tagged at the wrong place
# describing a different commit than the one it actually points at.
#
# Fix chosen: refuse outright unless the remote tag already exists AND
# matches the commit gate 1 verified -- this script does not push a tag
# itself (every other push on this fleet is a distinct, operator-typed git
# command; making --apply's blast radius "verify + create a Release" and
# nothing more is easier to reason about) and does not force-update a
# mismatched remote tag (silently overwriting someone else's tag is a worse
# surprise than just refusing). `--target` and `--verify-tag` are then
# passed to `gh release create` too, as redundant belt-and-suspenders: if
# this check and the API call ever raced, --verify-tag makes gh itself
# abort rather than auto-tag, and --target pins the commit if gh does end
# up creating the tag.
say "verifying remote tag matches the commit gate 1 verified"
REMOTE_TAG_COMMIT="$(git -C "$REPO" ls-remote origin "refs/tags/${VERSION}" "refs/tags/${VERSION}^{}" 2>/dev/null \
    | awk '{print $1}' | tail -1)"
if [ -z "$REMOTE_TAG_COMMIT" ]; then
    say "FATAL: tag '$VERSION' exists locally at $TAG_COMMIT but has not been pushed to $GH_REPO -- push it first (git push origin refs/tags/$VERSION) and re-run. Refusing to let 'gh release create' auto-tag the wrong commit."
    exit 1
elif [ "$REMOTE_TAG_COMMIT" != "$TAG_COMMIT" ]; then
    say "FATAL: tag '$VERSION' exists on the remote but points at $REMOTE_TAG_COMMIT, not the commit gate 1 verified ($TAG_COMMIT) -- refusing to proceed. This script will not overwrite a mismatched tag; reconcile it manually."
    exit 1
fi
say "remote tag OK: refs/tags/$VERSION -> $REMOTE_TAG_COMMIT"

PREV_TAG="$(git -C "$REPO" tag --merged origin/main --sort=-v:refname 2>/dev/null \
    | grep -vE -- '-dev|\+' \
    | awk -v cur="$VERSION" 'found{print; exit} $0==cur{found=1}')"
if [ -n "$PREV_TAG" ]; then
    CHANGELOG="$(git -C "$REPO" log --oneline "${PREV_TAG}..${VERSION}")"
else
    CHANGELOG="(no previous tag -- first release)"
fi

# $PREV_TAG is an operator-chosen git tag NAME -- a PRIOR release's tag,
# not this one, so gate 0 never validated it and never will (gate 0 only
# ever looks at $VERSION, the tag being blessed right now). It is used
# above to compute the git log range and nowhere else: it must never reach
# $NOTES itself. A reviewer proved why the hard way, against the real
# hard-abort scan: tag a poisoned prior release (e.g.
# `v9.0.0-root@10.0.0.5`), merge it to origin/main, then tag a completely
# clean NEXT version -- the clean release's own notes would still contain
# that old tag's name verbatim in the "### Changelog since <tag>" header,
# and the hard-abort tier is RIGHT to refuse publishing it: the text
# really would appear in a public Release if allowed through. That is a
# true positive, not a false one, and excluding this line from the scan
# (rather than fixing what gets published) would silence a real leak.
#
# The actual fix is to stop publishing the tag NAME at all -- the header
# only exists to tell a reader what range the changelog covers, and a
# short commit SHA does that job without dragging an arbitrary
# operator-chosen string into published output. $PREV_TAG keeps doing its
# job internally (the git log range above already used it); only the
# SAFE, script-computed SHA derived from it goes into $NOTES.
PREV_TAG_COMMIT=""
if [ -n "$PREV_TAG" ]; then
    PREV_TAG_COMMIT="$(git -C "$REPO" rev-parse --short "${PREV_TAG}^{commit}" 2>/dev/null)"
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
    if [ -n "$PREV_TAG_COMMIT" ]; then
        echo "### Changelog since $PREV_TAG_COMMIT"
    else
        echo "### Changelog (first release)"
    fi
    echo '```'
    echo "$CHANGELOG"
    echo '```'
} > "$NOTES"

# Leakage self-check -- SHAPES, not an enumerated list of known hostnames.
# A denylist of known names (the version before this one) only ever catches
# names someone already thought to list; a reviewer found this the hard way
# with a hypothetical commit message naming a runner this list had never
# heard of, and the real test-v3.log on this rig already contains
# /srv/build/v3/... paths that a denylist would also have missed.
#
# Scope is DIFFERENT PER TIER -- this took two attempts to get right, and
# the failure mode of getting it wrong is instructive enough to leave both
# attempts documented here rather than just the current answer.
#
# Attempt 1 scanned the whole $NOTES file with every shape. A reviewer
# found this self-defeating: "- Image: sigmond-appliance-v3.32-...img"
# matches the hyphenated-hostname shape as "appliance-v3" (gate 0 forces
# every version to start v[0-9]*, so this fired structurally on 100% of
# releases), and the hardcoded "...test-nested-v3.sh" verdict line matched
# the same shape as "nested-v3" regardless of version. NFLAGGED was never
# 0 in real usage, so the simple confirm phrase was unreachable and every
# release paid the deliberate-confirmation cost meant for real risk.
#
# Attempt 2 (over-corrected) scoped EVERYTHING, including the hard-abort
# checks, to the changelog body only -- on the reasoning that everything
# else in $NOTES is script-generated from gate-validated values and "can't
# carry a leak the script did not put there itself." That reasoning is
# right for the FLAGGED-tier shapes (paths, domains, hostname-shaped
# tokens -- these are exactly what matched the boilerplate above) but
# wrong for $VERSION specifically: it's an operator-supplied git tag name,
# and gate 0's positive check (v[0-9]*) barely constrains what follows the
# leading digit. A reviewer proved this against the committed script by
# creating the real tag `v1-root@192.168.1.14-leak` -- git accepts it
# (only "@{" is special) -- which is echoed verbatim into the title, the
# "- Version:" line, and (via $IMGBASE) the "- Image:" line. Scoping the
# hard-abort checks to the changelog meant NONE of those lines were ever
# scanned, so a poisoned tag sailed straight through to the simple confirm
# phrase with a real IP and a real user@host string sitting in the
# published notes.
#
# So: HARD-ABORT shapes (IPv4, user@host) scan the FULL $NOTES -- they
# never collided with the boilerplate in the first place (verified
# directly below), so there was never a reason to narrow them, and
# $VERSION is exactly the kind of operator-supplied text they exist to
# catch. FLAGGED shapes stay scoped to the changelog body -- that's where
# the real boilerplate collision was, and where narrowing was actually
# needed.
#
# I considered other things interpolated into $NOTES and either brought
# them into scope or deliberately did not:
#   - $PREV_TAG itself does NOT reach $NOTES at all (see the block above
#     this one) -- only its resolved commit SHA does, precisely so this
#     scan never has to make a judgment call about whether an old tag
#     name is safe to publish. An earlier version of this comment argued
#     the tag name was fine to leave unscanned because "it already leaked
#     the moment it was pushed" -- a reviewer correctly rejected that: a
#     prior leak does not make republishing the same string in a NEW
#     public Release harmless, and a reviewer proved the practical cost by
#     tagging a poisoned prior release, merging it to origin/main, then
#     tagging a completely clean next version -- whose own notes still
#     carried the old tag's name in the header, correctly hard-aborting a
#     release that had nothing wrong with it. Removing the tag name from
#     published output fixes that at the source instead of arguing about
#     whether to scan it.
#   - the attached manifest/sha256 files themselves are NOT interpolated
#     into the notes TEXT at all (gh attaches them as separate binary/text
#     assets), so they're out of scope for a check about what's IN the
#     notes. Worth flagging anyway: a manifest captured off a long-lived,
#     drifted install (not a fresh golden template) can carry a free-text
#     "updates since install" section with operator-written entries -- see
#     the Task 3 report's own sample. In practice this is narrower than it
#     sounds -- Task 3's capture point runs immediately after
#     provisioning, before any post-install drift can occur, so a fresh
#     golden-template build structurally cannot produce that section, and
#     a leakage grep against a realistic manifest sample came back clean.
#     But UNLIKE the changelog, the manifest's contents are never PRINTED
#     to the operator before the confirmation prompt below -- only the
#     notes text is. So if this residual risk were ever hit (a manifest
#     captured some other way, or the capture point's guarantee breaking
#     later), there is no human backstop for it at all, not even the
#     deliberate-confirmation one. That is a real gap, left as a gap
#     rather than silently assumed covered.
#
# Two tiers, split by how often the shape is legitimately part of ordinary
# release-note prose on this fleet vs. how bad it is to miss:
#
#   HARD ABORT (no recourse, ever): an IPv4 literal, a user@host reference.
#   Both are near-unambiguous evidence of a specific network identity or
#   credential context -- release notes never legitimately need either, so
#   there is nothing for a human to "wave through."
#
#   FLAGGED (human must acknowledge, deliberately): everything shape-ier
#   than that -- absolute paths (Unix and Windows), a dotted name under a
#   real-looking TLD, and two hostname-shaped-token heuristics. A reviewer
#   measured the false-positive cost of treating these as hard aborts: the
#   Unix-path shape alone fires on a meaningful fraction of ordinary commit
#   messages on this fleet (a date like 8/16, a ratio like 20/21, a version
#   like 3.24.0/stable, a GitHub issue URL) because this fleet's commit
#   messages are heavy on exactly that kind of text. A hard abort with no
#   recourse but rewriting git history trains whoever hits it first to
#   comment the check out -- a guard that gets removed protects nothing.
#   So these inform the human instead of replacing them: they're printed
#   with what matched and why, and acknowledging them requires a more
#   deliberate confirmation than a clean run (below), not just a bigger
#   red warning the operator learns to scroll past.
#
# The changelog is raw `git log --oneline` text, so every line starts with
# a short hex commit hash -- and a hex hash (e.g. "aca5772") itself matches
# the letters-then-digits hostname shape below on nearly every line,
# drowning any real signal. Now that the scan is scoped to a file
# containing ONLY changelog lines (see CHANGELOG_FILE below), that strip
# can be applied to the whole file safely and simply -- there is no longer
# any non-changelog content in the same file it could bleed into by
# accident (the fence-toggling awk state machine from the previous version
# existed only to guard against that, and is no longer needed once the
# scope itself excludes non-changelog text).
#
# Known gaps, left as gaps deliberately rather than papered over -- human
# review (below) is load-bearing for these, not this regex:
#   - a hostname that is pure letters with no digit (or a real word used
#     as a hostname) matches no shape here at all
#   - IPv6 literals are not matched (IPv4 is)
#   - a credential or identity string with no @ and no path separator
#     (e.g. a bare API key or token) matches nothing here
#   - a description of internal topology in plain English ("the box next
#     to the antenna switch") matches nothing here and never will by shape
CHANGELOG_FILE="$(mktemp)"
printf '%s\n' "$CHANGELOG" > "$CHANGELOG_FILE"

# Collected per DISTINCT LINE, same reasoning as the flagged tier below:
# a line matching both shapes (e.g. "root@192.168.1.14" is simultaneously
# an IPv4 address AND a user@host reference) should report once, not
# twice, with every reason attached.
declare -A HARD_LINE_LABELS=()
note_hard(){ # note_hard <label> <newline-separated "N:..." grep -n output>
    local label="$1" hits="$2" ln
    [ -n "$hits" ] || return 0
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        if [ -n "${HARD_LINE_LABELS[$ln]:-}" ]; then
            HARD_LINE_LABELS[$ln]="${HARD_LINE_LABELS[$ln]}, $label"
        else
            HARD_LINE_LABELS[$ln]="$label"
        fi
    done <<< "$(printf '%s\n' "$hits" | cut -d: -f1)"
}

# ---- hard-abort tier: scans the FULL $NOTES, not just the changelog ----
# $VERSION is operator-supplied (it is whatever the git tag on HEAD says)
# and gate 0 barely constrains it -- it only rejects "-dev" and "+"; its
# positive check is the case pattern v[0-9]*, which is "v" + one digit +
# ANYTHING. git tags happily accept an "@" and dotted-quad-looking runs
# too (only "@{" is special to git). $VERSION is echoed verbatim into the
# title, the "- Version:" line, and (via $IMGBASE) the "- Image:" line --
# none of which the changelog-only scope above ever looks at. A reviewer
# proved this against this exact script by creating the real tag
# `v1-root@192.168.1.14-leak`: it passed gates 0-5, the changelog-scoped
# leak check reported clean, and the notes -- containing a real IP AND a
# real user@host string, verbatim, twice -- reached the simple confirm
# phrase with zero friction.
#
# So the two tiers are scoped differently, on purpose, because they have
# different collision profiles. IPv4 and user@host NEVER collided with the
# boilerplate (verified directly: neither shape matches any of the
# version/commit/image/sha256/verdict lines for a normal release) -- the
# boilerplate collision that justified narrowing the FLAGGED tier (below)
# never applied to these two. Restoring full-$NOTES coverage here costs
# nothing and closes the tag-name hole outright, with no override
# possible -- exactly like every other hard-abort case.
note_hard "an IPv4 address" \
    "$(grep -nE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$NOTES" || true)"
note_hard "a user@host reference" \
    "$(grep -nE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+' "$NOTES" || true)"

if [ ${#HARD_LINE_LABELS[@]} -gt 0 ]; then
    say "FATAL: the release notes contain a hard-stop leak shape -- refusing to publish. No confirmation can override this. Line-by-line remedy:"
    for ln in $(printf '%s\n' "${!HARD_LINE_LABELS[@]}" | sort -n); do
        LINE_TEXT="$(sed -n "${ln}p" "$NOTES")"
        # The remedy depends on WHERE the match is, not just what matched.
        # A hit in a script-generated field means the CURRENT tag itself
        # is poisoned (the only operator-supplied text that reaches these
        # specific lines is $VERSION, echoed at the title/Version/Image
        # lines); a hit anywhere else is changelog content, where "fix
        # the tag" does nothing -- the offending text lives in a past
        # commit message already in history.
        case "$LINE_TEXT" in
            "## sigmond-appliance "*|"- Version: "*|"- Image: "*)
                REMEDY="the CURRENT tag ($VERSION) is poisoned -- delete it (git tag -d $VERSION; git push origin :refs/tags/$VERSION if it was pushed) and re-tag with a clean name, then re-run" ;;
            "- Appliance commit: "*|"- SHA-256: "*|"- Test verdict:"*)
                REMEDY="this is a script-generated field that should be pure hex/literal text and should never match this shape -- something is wrong upstream of this script; do not trust anything else this run produced until that's understood" ;;
            *)
                REMEDY="this is changelog content -- a past commit message already in history. Re-tagging does not fix it; the commit needs to be excluded from what ships (adjust the release range) or the leak needs to be handled out of band (e.g. rewriting that commit's message and force-pushing, which has its own costs)" ;;
        esac
        printf '  line %s: %s\n    matched: %s\n    remedy: %s\n' "$ln" "$LINE_TEXT" "${HARD_LINE_LABELS[$ln]}" "$REMEDY"
    done
    rm -f "$NOTES" "$CHANGELOG_FILE"
    exit 1
fi

# ---- flagged tier ----
# Collected per DISTINCT LINE, not per occurrence: a line matching two
# shape categories (e.g. a path that also looks like a hostname) is
# recorded once, with both reasons attached, and counted once. A reviewer
# caught this the hard way in the previous version: counting occurrences
# instead of lines meant the printed tally and the number the confirmation
# phrase required could differ from what an operator would count by eye,
# which makes an honest, careful operator fail the confirmation on the
# first try -- exactly the muscle-memory-proof design fighting itself.
declare -A LINE_LABELS=()
note_flag(){ # note_flag <label> <newline-separated "N:..." grep -n output>
    local label="$1" hits="$2" ln
    [ -n "$hits" ] || return 0
    while IFS= read -r ln; do
        [ -n "$ln" ] || continue
        if [ -n "${LINE_LABELS[$ln]:-}" ]; then
            LINE_LABELS[$ln]="${LINE_LABELS[$ln]}, $label"
        else
            LINE_LABELS[$ln]="$label"
        fi
    done <<< "$(printf '%s\n' "$hits" | cut -d: -f1)"
}

note_flag "an absolute Unix path" \
    "$(grep -nE '/[A-Za-z0-9_.-]{2,}' "$CHANGELOG_FILE" || true)"
note_flag "a Windows-style path (drive letter)" \
    "$(grep -nE '\b[A-Za-z]:\\' "$CHANGELOG_FILE" || true)"
note_flag "a domain name (name.tld shape)" \
    "$(grep -nE '\b[A-Za-z0-9-]{1,63}\.(com|org|net|io|edu|gov|mil|local|lan|internal|dev|app|co)\b' "$CHANGELOG_FILE" || true)"
SCRUBBED_FOR_HOSTNAME_CHECK="$(sed -E 's/^[0-9a-f]{7,40}[[:space:]]+//' "$CHANGELOG_FILE")"
note_flag "a short hostname-shaped token (letters+digits)" \
    "$(printf '%s\n' "$SCRUBBED_FOR_HOSTNAME_CHECK" | grep -nE '\b[A-Za-z]{2,}[0-9]{1,4}\b' || true)"
note_flag "a hyphenated hostname-shaped token (e.g. b4-prox)" \
    "$(printf '%s\n' "$SCRUBBED_FOR_HOSTNAME_CHECK" | grep -nE '\b[A-Za-z]{1,6}[0-9]{1,3}-[A-Za-z0-9]{1,20}\b|\b[A-Za-z0-9]{1,20}-[A-Za-z]{1,6}[0-9]{1,3}\b' || true)"

NFLAGGED=${#LINE_LABELS[@]}
if [ "$NFLAGGED" -gt 0 ]; then
    say "$NFLAGGED distinct changelog line(s) flagged -- shape-based, may be false positives, but must be read before publishing:"
    for ln in $(printf '%s\n' "${!LINE_LABELS[@]}" | sort -n); do
        printf '  line %s: %s\n    matched: %s\n' "$ln" "$(sed -n "${ln}p" "$CHANGELOG_FILE")" "${LINE_LABELS[$ln]}"
    done
else
    say "leakage self-check clean (changelog: no hard-stop or flagged shapes matched)"
fi
rm -f "$CHANGELOG_FILE"

# Human confirmation -- the only backstop that covers what the shapes above
# cannot (see "Known gaps" in the comment above). Read from /dev/tty
# explicitly so a non-interactive invocation (cron, CI, a script piping
# input) cannot be mistaken for consent -- it fails closed instead.
#
# A flagged run requires a MORE deliberate confirmation than a clean run --
# the exact count of DISTINCT flagged lines (matching what was just
# printed) must appear in the typed phrase, which is only possible if the
# operator actually looked at the count just printed, rather than
# reflexively retyping a memorized phrase.
say "----- RELEASE NOTES ($VERSION) -- read before confirming -----"
cat "$NOTES"
say "----- END RELEASE NOTES -----"
if [ "$NFLAGGED" -eq 0 ]; then
    PROMPT="Type exactly 'publish $VERSION' to confirm publication to $GH_REPO (anything else aborts): "
    REQUIRED="publish $VERSION"
else
    PROMPT="$NFLAGGED changelog line(s) were flagged above. Type exactly 'I reviewed $NFLAGGED flagged lines, publish $VERSION' to confirm anyway (anything else aborts): "
    REQUIRED="I reviewed $NFLAGGED flagged lines, publish $VERSION"
fi
if ! CONFIRM="$(read -r -p "$PROMPT" REPLY < /dev/tty && echo "$REPLY")"; then
    say "FATAL: could not read a confirmation from a terminal (/dev/tty) -- refusing to publish non-interactively"
    rm -f "$NOTES"
    exit 1
fi
if [ "$CONFIRM" != "$REQUIRED" ]; then
    say "confirmation not given -- aborting, nothing published"
    rm -f "$NOTES"
    exit 1
fi

say "publishing Release $VERSION on $GH_REPO"
gh release create "$VERSION" --repo "$GH_REPO" \
    --title "sigmond-appliance $VERSION" --notes-file "$NOTES" \
    --target "$TAG_COMMIT" --verify-tag \
    "$MANIFEST" "$SHAFILE"
RC=$?
rm -f "$NOTES"
exit $RC
