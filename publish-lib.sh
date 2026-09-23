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
# pub_describe — print the resolved destinations. Call before any upload so
# the log always answers "where did this go?" without reading the script.
pub_describe() {
    local i
    for i in "${!PUB_DESTS[@]}"; do
        printf '   %-6s %-10s %s\n' "${PUB_LABELS[$i]}" "${PUB_STAGES[$i]}" "${PUB_DESTS[$i]}"
    done
}
