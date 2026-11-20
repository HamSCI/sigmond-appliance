# release-home-lib.sh -- the image build's reads of sigmond's release list.
# Sourced by build-usb-v3.sh (and the tests); defines functions only.
#
# sigmond holds the version: release/components.toml at the sigmond commit
# the golden VM installed names every component's commit.  These helpers
# read that file out of a sigmond checkout with `git show`, and hand it to
# sigmond's own parser (`python3 -m sigmond.release_list`) for every
# judgement, so the rig never parses the list a second way.
#
# The golden VM's sigmond commit (C4) is one full commit in
# <rig v3 dir>/golden-v3-sigmond-commit.txt, written by build-golden-vm.sh.

# python3 with the checkout's own sigmond library first on the path.
_rh_py() {
    local repo="$1"; shift
    PYTHONPATH="$repo/lib${PYTHONPATH:+:$PYTHONPATH}" python3 "$@"
}

# rh_sigmond_commit <rig_v3_dir>: print C4's commit, or fail with a reason.
rh_sigmond_commit() {
    local f="$1/golden-v3-sigmond-commit.txt" c
    [ -r "$f" ] || { echo "release-home: $f missing (build the golden VM first)" >&2; return 1; }
    c="$(tr -d '[:space:]' < "$f")"
    if ! [[ "$c" =~ ^[0-9a-f]{40}$ ]]; then
        echo "release-home: $f holds '$c', not one full 40-hex commit" >&2
        return 1
    fi
    printf '%s\n' "$c"
}

# rh_list_text <sigmond_repo> <commit>: the list as committed there.
rh_list_text() {
    git -C "$1" show "$2:release/components.toml" 2>/dev/null && return 0
    echo "release-home: sigmond $2 holds no release/components.toml" >&2
    return 1
}

# rh_version <sigmond_repo> <commit>: the list's version, e.g. v3.94.
rh_version() {
    local text
    text="$(rh_list_text "$1" "$2")" || return 1
    printf '%s\n' "$text" | _rh_py "$1" -m sigmond.release_list version --list -
}

# rh_check_manifest <sigmond_repo> <commit> <manifest>: the exit of
# `release_list check` (0 match, 1 mismatch with one line per row, 2 error).
rh_check_manifest() {
    local text
    text="$(rh_list_text "$1" "$2")" || return 2
    printf '%s\n' "$text" | _rh_py "$1" -m sigmond.release_list check --list - --manifest "$3"
}

# rh_row <sigmond_repo> <commit> <name>: the list's commit for one row.
rh_row() {
    local text
    text="$(rh_list_text "$1" "$2")" || return 1
    printf '%s\n' "$text" | _rh_py "$1" -c '
import sys
from sigmond.release_list import ReleaseListError, parse_list
try:
    rows = parse_list(sys.stdin.read()).components
except ReleaseListError as e:
    sys.exit("release_list: %s" % e)
if sys.argv[1] not in rows:
    sys.exit("release_list: no row %s" % sys.argv[1])
print(rows[sys.argv[1]])
' "$3"
}

# rh_proxmox_row <sigmond_repo> <commit>: the list's sigmond-proxmox commit.
rh_proxmox_row() { rh_row "$1" "$2" sigmond-proxmox; }

# rh_seat <dir> <url> <commit>: leave <dir> a clean checkout of <url> at
# <commit>, detached, or fail with a reason.  Clones when <dir> holds none
# (shallow: only the commit's tree ships), fetches the commit when absent
# (a shallow clone has only its own tip), and never pulls a branch.
rh_seat() {
    local dir="$1" url="$2" commit="$3" head
    if [ ! -d "$dir/.git" ]; then
        git clone -q --depth 1 "$url" "$dir" \
            || { echo "release-home: cannot clone $url into $dir" >&2; return 1; }
    fi
    if ! git -C "$dir" cat-file -e "$commit^{commit}" 2>/dev/null; then
        git -C "$dir" fetch -q --depth 1 origin "$commit" 2>/dev/null \
            || { echo "release-home: cannot fetch $commit into $dir (pushed?)" >&2; return 1; }
    fi
    git -C "$dir" checkout -q --detach "$commit" 2>/dev/null \
        || { echo "release-home: cannot check out $commit in $dir" >&2; return 1; }
    head="$(git -C "$dir" rev-parse HEAD)"
    if [ "$head" != "$commit" ]; then
        echo "release-home: $dir sits at $head, not $commit" >&2; return 1
    fi
    if [ -n "$(git -C "$dir" status --porcelain --untracked-files=no)" ]; then
        echo "release-home: $dir has local changes; the payload would not be $commit" >&2
        return 1
    fi
}
