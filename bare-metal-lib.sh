# bare-metal-lib.sh -- the bare-metal install test's record (contract C2).
# Sourced by test-bare-metal.sh (and the tests); defines functions only.
#
# One record per run, $RIG_DIR/bare-metal/<version>-<YYYYmmddTHHMMSSZ>.record,
# "key: value" lines.  sigmond's release/bless-release.sh gate 10 reads them:
# it takes the NEWEST record for the version and the sigmond commit, newest
# by the stamp in the file NAME (not finished_utc), and blesses only on
# result: PASS.  bm_newest picks the same record the same way.

# bm_record <dir> <version> <commit> <digest> <list_rc> <check_exit> <judge_rc>
# Write one record and print its path.
#   list_rc     exit of `smd admin release-list --check` in the VM (0 = match)
#   check_exit  exit of `smd check --json` (0 ok, 2 waits; -1 = never ran)
#   judge_rc    exit of `python3 -m sigmond.bare_metal_doc judge` (0 = pass)
# result: PASS only for list_rc 0, judge_rc 0 and check_exit 0 or 2.
# BM_NOW_EPOCH fixes the clock (tests).  Never overwrites a record.
bm_record() {
    local dir="$1" ver="$2" commit="$3" digest="$4" lrc="$5" cex="$6" jrc="$7"
    local now stamp iso path lst cons res
    [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "bare-metal: commit '$commit' is not 40 hex" >&2; return 1; }
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "bare-metal: digest '$digest' is not 64 hex" >&2; return 1; }
    [[ "$cex" =~ ^-?[0-9]+$ ]] || { echo "bare-metal: smd check exit '$cex' is not an integer" >&2; return 1; }
    now="${BM_NOW_EPOCH:-$(date -u +%s)}"
    stamp="$(date -u -d "@$now" +%Y%m%dT%H%M%SZ)"
    iso="$(date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
    path="$dir/$ver-$stamp.record"
    [ -e "$path" ] && { echo "bare-metal: $path exists; a record is never overwritten" >&2; return 1; }
    lst=FAIL;  [ "$lrc" = 0 ] && lst=PASS
    cons=FAIL; [ "$jrc" = 0 ] && cons=PASS
    res=FAIL
    if [ "$lst" = PASS ] && [ "$cons" = PASS ] && { [ "$cex" = 0 ] || [ "$cex" = 2 ]; }; then
        res=PASS
    fi
    mkdir -p "$dir" || return 1
    printf '%s\n' \
        "bare_metal_record: 1" \
        "version: $ver" \
        "sigmond_commit: $commit" \
        "doc_commands_sha256: $digest" \
        "release_list_check: $lst" \
        "smd_check_exit: $cex" \
        "radiod_consumers: $cons" \
        "result: $res" \
        "finished_utc: $iso" > "$path.tmp" && mv "$path.tmp" "$path" || return 1
    printf '%s\n' "$path"
}

_bm_key() { awk -F': *' -v k="$2" '$1==k {sub(/^[^:]*: */,""); print; exit}' "$1"; }

# bm_newest <dir> <version> <commit>: the newest record for that version at
# that sigmond commit, by the name's stamp, as gate 10 picks it.  Fails when
# none matches.
bm_newest() {
    local dir="$1" ver="$2" commit="$3" f found=""
    while IFS= read -r f; do
        [ "$(_bm_key "$f" bare_metal_record)" = 1 ] || continue
        [ "$(_bm_key "$f" version)" = "$ver" ] || continue
        [ "$(_bm_key "$f" sigmond_commit)" = "$commit" ] || continue
        found="$f"
    done < <(find "$dir" -maxdepth 1 -type f -name "${ver}-*.record" 2>/dev/null | LC_ALL=C sort)
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

# bm_bringup_partial_ok <rc> <output-file>: true when the doc's bring-up
# ended PARTIAL for want of an SDR, which on the rig's VM (no RX888) is the
# doc's success.  smd bringup then exits 3 (BRINGUP_PARTIAL_RC) and prints
# its PARTIAL-for-no-SDR line, matched here as smd prints it (bin/smd
# _bringup_finish; bare-metal v3.94 run 2, 2026-11-21).  Narrow on purpose:
# exit 3 without that line, any other exit, and a PARTIAL run that also
# reports a failed step (smd returns 3 for it too) all stay a failed doc step.
BM_PARTIAL_NO_SDR="' PARTIAL — no SDR, so radiod and the radiod-bound clients are installed but not configured or started."
bm_bringup_partial_ok() {
    local rc="$1" out="$2"
    [ "$rc" = 3 ] && [ -r "$out" ] || return 1
    grep -qF "bringup '" "$out" && grep -qF -- "$BM_PARTIAL_NO_SDR" "$out" || return 1
    ! grep -qF 'bring-up step(s) FAILED' "$out"
}
