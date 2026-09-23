#!/bin/bash
# sync-rig.sh — put the build rig's working directory in step with git.
#
# ⛔ Why this exists.  The rig builds from /srv/build/v3 (reached as
# /root/appliance/v3), which is NOT a git checkout — it holds loose copies
# that someone updated by hand.  On 2026-09-22 its rob.pub had diverged from
# the repo's and every decoder VM built there, v3.48 through v3.50 and AI6VN
# with them, answered to one key alone.  It looked like the VMs were keyless.
# They were not; they had a key nobody was trying.
#
# Hand-copying the next change repeats that.  This script makes the sync one
# command, deterministic, and loud about what it changed.
#
# Usage:   ./sync-rig.sh [--dry-run]
#          run it ON the rig, from the git checkout.
set -eu
DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="${RIG_BUILD_DIR:-/srv/build/v3}"

[ -d "$SRC/.git" ] || { echo "FATAL: $SRC is not a git checkout — sync FROM git, never from another copy"; exit 1; }
[ -d "$DST" ]      || { echo "FATAL: build dir $DST does not exist"; exit 1; }

# Refuse to publish a dirty tree's idea of the truth.  If the checkout has
# uncommitted edits, what lands on the rig is not what git records, and the
# next person to ask "what did we build from?" gets a wrong answer.
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "FATAL: $SRC has uncommitted changes — commit or stash first:"
    git -C "$SRC" status --short | sed 's/^/    /'
    exit 1
fi

echo "sync-rig: $SRC ($(git -C "$SRC" rev-parse --short HEAD)) -> $DST"
[ "$DRY" = 1 ] && echo "  (dry run — nothing will be written)"

# Everything git tracks at the top level, plus operators/.  Deriving the list
# from git rather than naming files means a new build input can never be
# forgotten here; forgetting one is exactly how rob.pub diverged.
CHANGED=0
while IFS= read -r rel; do
    case "$rel" in */*) [ "${rel%%/*}" = "operators" ] || continue ;; esac
    s="$SRC/$rel"; d="$DST/$rel"
    [ -f "$s" ] || continue
    if [ -f "$d" ] && cmp -s "$s" "$d"; then continue; fi
    CHANGED=$((CHANGED+1))
    if [ -f "$d" ]; then echo "  UPDATE $rel"; else echo "  NEW    $rel"; fi
    [ "$DRY" = 1 ] && continue
    mkdir -p "$(dirname "$d")"
    cp -p "$s" "$d"
    [ -x "$s" ] && chmod +x "$d"
done < <(git -C "$SRC" ls-files)

# A key file the repo no longer carries must not keep authorizing anyone.
# Revocation that only happens in git is not revocation.
if [ -d "$DST/operators" ]; then
    for f in "$DST"/operators/*.pub; do
        [ -e "$f" ] || continue
        [ -f "$SRC/operators/$(basename "$f")" ] && continue
        echo "  ⚠ STALE  operators/$(basename "$f") — in the rig, NOT in git (revoked?)"
        echo "           remove it by hand once you have confirmed it should go"
    done
fi
# The legacy single-file key set is now operators/rob.pub.  Leaving it in
# place is harmless (the build prefers operators/) but it is the file that
# caused the divergence, so say it is there.
[ -f "$DST/rob.pub" ] && echo "  note: legacy $DST/rob.pub still present; operators/ takes precedence"

echo "sync-rig: $CHANGED file(s) $([ "$DRY" = 1 ] && echo 'would change' || echo 'updated')"
