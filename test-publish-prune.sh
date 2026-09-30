#!/bin/bash
# test-publish-prune.sh — pub_superseded picks exactly the right files to delete.
#
# ⛔ WHY THIS EXISTS.  pending/ only ever grew: nothing removed a superseded
# image, so by 2026-09-30 rob's Drive held v3.57 through v3.61 -- five 5.2 GiB
# images on a 150 GiB quota he was running out of.  It is also a CORRECTNESS
# problem, not only housekeeping: he installed v3.59 by accident that same night
# because a superseded image was still lying around to be picked by name.
#
# mjh added the pruning at bless (6b9b38f); the build now runs the same helpers
# after each upload too, because a bless is rare and pending/ grows one image
# per build in between.
#
# The subtle requirement is the one a naive "keep only what I just uploaded"
# would get wrong: a NEWER candidate may be sitting in pending/ while an older
# one is being blessed, and deleting it would throw away an image nobody else
# has.  test_keeps_newer is the guard on that.
#
#   usage: ./test-publish-prune.sh [path/to/publish-lib.sh]
set -u
LIB="${1:-$(dirname "$0")/publish-lib.sh}"
[ -f "$LIB" ] || { echo "FATAL: no publish-lib.sh at $LIB"; exit 1; }
# shellcheck disable=SC1090
. "$LIB"

PASS=0; FAIL=0
chk(){ # chk <desc> <got> <want>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }

V357=sigmond-appliance-v3.57-20260929-release
V359=sigmond-appliance-v3.59-20260930-release
V360=sigmond-appliance-v3.60-20260930-release
V361=sigmond-appliance-v3.61-20260930-release
V361B=sigmond-appliance-v3.61-20261001-release   # same version, rebuilt next day
V4=sigmond-appliance-v4.0-20261005-release

PENDING="$V357.img $V357.sha256 $V359.img $V359.sha256 $V360.img \
$V361.img $V361.sha256 $V361.manifest.txt NOTES.txt keep-me.tar.gz"

# ── what v3.61 supersedes ───────────────────────────────────────────────────
got=$(pub_superseded "$V361.img" $PENDING | sort | tr '\n' ' ')
chk "prunes every lower version, all extensions" "$got" \
    "$V357.img $V357.sha256 $V359.img $V359.sha256 $V360.img "

# ── the keeper survives ─────────────────────────────────────────────────────
chk "never prunes the release just uploaded" \
    "$(pub_superseded "$V361.img" $PENDING | grep -c "^$V361\.")" "0"

# ── files with no version are not ours to touch ─────────────────────────────
chk "leaves unversioned files alone" \
    "$(pub_superseded "$V361.img" $PENDING | grep -cE '^(NOTES\.txt|keep-me\.tar\.gz)$')" "0"

# ── ⛔ a NEWER candidate must survive ────────────────────────────────────────
# Blessing v3.59 while v3.60/v3.61 wait in pending/ must not delete them: they
# are candidates nobody else holds. This is what makes the version compare
# necessary rather than "keep only my own name".
got=$(pub_superseded "$V359.img" $PENDING | sort | tr '\n' ' ')
chk "keeps HIGHER versions when an older one is blessed" "$got" \
    "$V357.img $V357.sha256 "

# ── same version, different build date ──────────────────────────────────────
# The blessed build is that version's only authority, so a same-version build
# from another day goes.
chk "prunes a same-version build from another day" \
    "$(pub_superseded "$V361.img" "$V361B.img" "$V361.img")" "$V361B.img"

# ── version ordering is numeric, not lexical ────────────────────────────────
# This project's minor is an increasing INTEGER: v3.6, v3.8, v3.20 ... v3.61.
# So v3.9 is OLDER than v3.61 and must be pruned -- but lexically "3.9" sorts
# AFTER "3.61" (because '9' > '6'), so a plain `sort` here would keep it
# forever. sort -V comparing component-wise is what makes this right, and this
# assertion is the only thing standing between that and a silent regression.
chk "v3.9 IS superseded by v3.61 (numeric, not lexical, compare)" \
    "$(pub_superseded "$V361.img" sigmond-appliance-v3.9-20261002-release.img)" \
    "sigmond-appliance-v3.9-20261002-release.img"
chk "v4.0 is NOT superseded by v3.61" \
    "$(pub_superseded "$V361.img" "$V4.img")" ""

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
