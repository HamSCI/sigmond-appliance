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

# pub_describe — print the resolved destinations. Call before any upload so
# the log always answers "where did this go?" without reading the script.
pub_describe() {
    local i
    for i in "${!PUB_DESTS[@]}"; do
        printf '   %-6s %-10s %s\n' "${PUB_LABELS[$i]}" "${PUB_STAGES[$i]}" "${PUB_DESTS[$i]}"
    done
}
