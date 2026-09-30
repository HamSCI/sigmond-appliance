# publish-lib.sh — shared by build-usb-v3.sh and bless-release.sh.
# Sourced, never executed.  Reads publish-targets.conf into PUB_LABELS /
# PUB_DESTS (parallel arrays) and refuses to continue if it declares nothing:
# a build whose products go nowhere should stop, not succeed quietly.
pub_load() {
    local conf="${1:-$PWD/publish-targets.conf}"
    PUB_LABELS=(); PUB_DESTS=(); PUB_STAGES=()
    [ -f "$conf" ] || { echo "FATAL: $conf missing — no publish destination declared" >&2; return 1; }
    local label dest stage
    while read -r label dest stage _; do
        case "$label" in ''|\#*) continue ;; esac
        [ -n "$dest" ] || { echo "FATAL: $conf: target '$label' has no destination" >&2; return 1; }
        stage="${stage:-pending}"
        case "$stage" in
            pending|blessed) ;;
            *) echo "FATAL: $conf: target '$label' has unknown stage '$stage' (want pending or blessed)" >&2; return 1 ;;
        esac
        PUB_LABELS+=("$label"); PUB_DESTS+=("$dest"); PUB_STAGES+=("$stage")
    done < "$conf"
    [ "${#PUB_DESTS[@]}" -gt 0 ] || { echo "FATAL: $conf declares no targets" >&2; return 1; }
    return 0
}
# ── transport ───────────────────────────────────────────────────────────────
# A destination is either an rclone remote ("gdrive:sigmond-images",
# "gdrive,root_folder_id=…:") or an ssh host written "ssh:<host>:<dir>"
# ("ssh:wd30:" = wd30's home directory).  wd30 is an ARCHIVE copy, not the
# download CDN: Drive stays the place downloaders fetch from (13770cd), wd30
# receives each build once so a copy exists outside any one person's Drive.
# Every caller goes through these three functions, so build and bless cannot
# disagree about how a target is reached.

# _pub_join <dest> <path> — "remote:" + "x" = "remote:x", "remote:dir" + "x" = "remote:dir/x"
_pub_join() { case "$1" in *:) echo "$1$2" ;; *) echo "${1%/}/$2" ;; esac; }

_pub_is_ssh() { case "$1" in ssh:*) return 0 ;; esac; return 1; }
_pub_ssh_host() { local r="${1#ssh:}"; echo "${r%%:*}"; }
_pub_ssh_dir()  { local r="${1#ssh:}"; r="${r#*:}"; echo "${r%/}"; }

# pub_put <dest> <subdir|""> <file>... — copy local files into dest[/subdir]/
pub_put() {
    local d="$1" sub="$2"; shift 2
    if _pub_is_ssh "$d"; then
        local h dir; h="$(_pub_ssh_host "$d")"; dir="$(_pub_ssh_dir "$d")"
        local tgt="${dir:+$dir/}${sub}"
        ssh -o BatchMode=yes "$h" "mkdir -p '${tgt:-.}'" || return 1
        scp -q -o BatchMode=yes "$@" "$h:${tgt:-.}/" || return 1
    else
        local f
        for f in "$@"; do
            rclone copyto -q "$f" "$(_pub_join "$d" "${sub:+$sub/}$(basename "$f")")" || return 1
        done
    fi
}

# pub_promote <dest> <name>... — move names from dest/pending/ up to dest/
pub_promote() {
    local d="$1"; shift
    if _pub_is_ssh "$d"; then
        local h dir q="" n; h="$(_pub_ssh_host "$d")"; dir="$(_pub_ssh_dir "$d")"
        for n in "$@"; do q="$q '$n'"; done
        ssh -o BatchMode=yes "$h" "cd '${dir:-.}/pending' && mv -f $q .." || return 1
    else
        local n
        for n in "$@"; do rclone moveto -q "$(_pub_join "$d" "pending/$n")" "$(_pub_join "$d" "$n")" || return 1; done
    fi
}

# pub_link <dest> <name> — a shareable link where the transport has one
pub_link() {
    local d="$1" dir
    if _pub_is_ssh "$d"; then
        dir="$(_pub_ssh_dir "$d")"
        echo "$(_pub_ssh_host "$d"):${dir:-~}/$2"
    else
        rclone link "$(_pub_join "$d" "$2")" 2>/dev/null
    fi
}

# pub_has_pending <dest> / pub_purge_pending <dest> — for blessed-only targets
pub_has_pending() {
    local d="$1" dir
    if _pub_is_ssh "$d"; then
        dir="$(_pub_ssh_dir "$d")"
        ssh -o BatchMode=yes "$(_pub_ssh_host "$d")" "test -d '${dir:-.}/pending'" 2>/dev/null
    else
        rclone lsf "$(_pub_join "$d" pending/)" >/dev/null 2>&1
    fi
}
pub_purge_pending() {
    local d="$1" dir
    if _pub_is_ssh "$d"; then
        dir="$(_pub_ssh_dir "$d")"
        ssh -o BatchMode=yes "$(_pub_ssh_host "$d")" "rm -rf '${dir:-.}/pending'"
    else
        rclone purge "$(_pub_join "$d" pending)" 2>/dev/null
    fi
}

# ── pruning superseded pending builds (mjh 2026-09-30) ─────────────────────
# pending/ accumulates one image per build, and a stale one is a live hazard:
# rob installed v3.59 by accident on 2026-09-30 because it was the file on his
# stick.  The bless therefore removes what the blessed image supersedes.

# _pub_version <name> — "sigmond-appliance-v3.61-20260930-release.img" → "3.61"
_pub_version() {
    printf '%s\n' "$1" | sed -nE 's/^sigmond-appliance-v([0-9]+(\.[0-9]+)+)-.*/\1/p'
}

# pub_superseded <blessed-img-basename> <name>... — print the names to delete.
# Deleted: any build of a LOWER version, and any other build of the SAME
# version (the blessed one is now that version's only authority).  Kept: the
# blessed build's own files, every HIGHER version (a newer candidate may be
# waiting in pending/ while an older one is blessed), and anything whose name
# carries no recognisable version.
pub_superseded() {
    local blessed="$1"; shift
    local bv bstem n v
    bv="$(_pub_version "$blessed")"; bstem="${blessed%.img}"
    [ -n "$bv" ] || return 0
    for n in "$@"; do
        case "$n" in "$bstem".*) continue ;; esac
        v="$(_pub_version "$n")"; [ -n "$v" ] || continue
        # sort -V puts the lower (or equal) of the two first.
        if [ "$(printf '%s\n%s\n' "$v" "$bv" | sort -V | head -1)" = "$v" ]; then
            echo "$n"
        fi
    done
}

# pub_list_pending <dest> — one file name per line from dest/pending/
pub_list_pending() {
    local d="$1" dir
    if _pub_is_ssh "$d"; then
        dir="$(_pub_ssh_dir "$d")"
        ssh -o BatchMode=yes "$(_pub_ssh_host "$d")" "ls -1 '${dir:-.}/pending' 2>/dev/null"
    else
        rclone lsf --files-only "$(_pub_join "$d" pending/)" 2>/dev/null
    fi
}

# pub_delete_pending <dest> <name>... — remove named files from dest/pending/
pub_delete_pending() {
    local d="$1"; shift
    [ "$#" -gt 0 ] || return 0
    if _pub_is_ssh "$d"; then
        local dir q="" n; dir="$(_pub_ssh_dir "$d")"
        for n in "$@"; do q="$q '$n'"; done
        ssh -o BatchMode=yes "$(_pub_ssh_host "$d")" "cd '${dir:-.}/pending' && rm -f $q"
    else
        local n
        for n in "$@"; do rclone deletefile "$(_pub_join "$d" "pending/$n")" || return 1; done
    fi
}

# pub_fetch_url <dest> <sub/name> — a URL any machine can curl, no credentials.
#
# ⛔ WHY.  A WsprDaemon station cannot install rclone just to receive an image,
# and most of them have no route to wd30 or gw2 at all: they sit behind NAT
# with nothing but an outbound frpc connection.  WB6CXC-7 on 2026-09-30 had
# general internet, no rclone, and no route to either gateway -- so the image
# was undeliverable despite the station being perfectly reachable FROM us.
# rob: "there's no reason for them to [install] rclone ... you should make sure
# [the three files] are publicly available and you can then use curl."
#
# `rclone link` shares the file (anyone WITH THE LINK may read; it is not
# listed or indexed) and returns a VIEWER url.  That viewer page is not a
# download: curl follows it to HTML, and for a multi-GB file Drive inserts a
# virus-scan interstitial as well.  drive.usercontent.google.com with
# `confirm=t` is the endpoint that streams the bytes, so that is what callers
# are handed.  Verified end to end from WB6CXC-7, which fetched a published
# checksum with no credentials of any kind.
pub_fetch_url() {
    local d="$1" p="$2" link id
    if _pub_is_ssh "$d"; then
        # Already a plain file on a host; scp is the fetch.
        pub_link "$d" "$p"
        return
    fi
    link="$(pub_link "$d" "$p")" || return 1
    [ -n "$link" ] || return 1
    # https://drive.google.com/open?id=<ID>  ->  the streaming endpoint
    case "$link" in
        *id=*) id="${link##*id=}"; id="${id%%&*}" ;;
        *)     printf '%s\n' "$link"; return 0 ;;
    esac
    printf 'https://drive.usercontent.google.com/download?id=%s&export=download&confirm=t\n' "$id"
}

# pub_describe — print the resolved destinations. Call before any upload so
# the log always answers "where did this go?" without reading the script.
pub_describe() {
    local i
    for i in "${!PUB_DESTS[@]}"; do
        printf '   %-6s %-10s %s\n' "${PUB_LABELS[$i]}" "${PUB_STAGES[$i]}" "${PUB_DESTS[$i]}"
    done
}
