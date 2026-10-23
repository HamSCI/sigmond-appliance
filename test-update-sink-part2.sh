#!/bin/bash
# test-update-sink-part2.sh — the readers and verdicts in test-update-v3.sh's
# sink2b_update block (sigmond step 2b part 2 across the update rig's E-bis,
# G-bis and G-ter: the carry-over runs once, the restore rolls it back, and
# the next update runs it again), fed real output.  No VM, no root.
#
#   usage: ./test-update-sink-part2.sh [path/to/test-update-v3.sh] [path/to/test-nested-v3.sh]
#
# Input comes from test-fixtures/sink-part2/, which capture.sh there copies
# from one sigmond commit (named in its SOURCE file):
#   manifest_step_part2.txt   the manifest step's V1 run (Task 19's capture)
#   restore_part2/            a restore to a sigmond below part 2, the next
#                             manifest step, and the switch files, markers
#                             and coordination.toml each left
#                             (tests/fixtures/capture_restore_part2.py)
#   pipelines_gate.toml, sigmond_gate.toml, pipelines_part1.toml
#                             the two render forms of the nest's manifest
#   manifest_step_part1.txt   part 1's manifest step (the restored release's)
#   update_plan_pull.txt      `smd update`'s plan lines, sigmond and
#                             hs-uploader one commit behind
# The re-attach (G-ter step 0) runs against real git repositories built
# here, with runuser stood in by a script that drops "-u <user> --".
# Every guest reply passes through wrap(), which builds what `qm guest exec`
# hands back (one JSON object whose "out-data" holds every line, each byte
# above 0x7F turned into its own character, so a UTF-8 sign arrives
# double-encoded), and then through the JSON reader gx itself runs, taken
# from test-update-v3.sh.
#
# The switch probe (UPL_SINKS) runs here for real, against scratch trees
# built from the captured files.  Negative cases derive from those files by
# one edit each, named where it is made.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-update-v3.sh}"
NESTED="${2:-$HERE/test-nested-v3.sh}"
FX="$HERE/test-fixtures/sink-part2"
RP="$FX/restore_part2"
eval "$(sed -n '/^# >>> sink_part2/,/^# <<< sink_part2/p' "$NESTED")"
eval "$(sed -n '/^# >>> sink2b_update/,/^# <<< sink2b_update/p' "$SRC")"
for fn in sp2_tok sp2u_step_facts sp2u_restore_facts sp2u_sum_diff sp2u_num \
          sp2u_ebis_verdict sp2u_gbis_verdict sp2u_gter_verdict sp2u_report \
          sp2u_moved sp2u_reattach_plan sp2u_reattach_script sp2u_reattach_verdict \
          sp2u_update_facts _sp2u_finish; do
    type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not found between its markers in $SRC or $NESTED"; exit 1; }
done
[ -n "${UPL_BRANCHES:-}" ] || { echo "FAIL: UPL_BRANCHES not found between the sink2b_update markers in $SRC"; exit 1; }
[ -n "${UPL_SINKS:-}" ] || { echo "FAIL: UPL_SINKS not found between the sink2b_update markers in $SRC"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
check(){ # <name> <want> <got>
    if [ "$2" = "$3" ]; then echo "  ok    $1"; else echo "  FAIL  $1: want '$2', got '$3'"; fail=1; fi
}
has(){ # <name> <file> <fixed text>: the file holds a line with the text
    if grep -qF -- "$3" "$2"; then echo "  ok    $1"; else echo "  FAIL  $1: no line holds '$3'"; sed 's/^/          | /' "$2"; fail=1; fi
}
hasnt(){ # <name> <file> <fixed text>
    if grep -qF -- "$3" "$2"; then echo "  FAIL  $1: a line holds '$3'"; sed 's/^/          | /' "$2"; fail=1; else echo "  ok    $1"; fi
}
nlines(){ grep -c -- "$2" "$1"; }
# clean <verdict> <name>: finished, and no FAIL line.
clean(){
    if grep -qx 'VERDICT:done' "$2" && ! grep -q '^FAIL:' "$2"; then echo "  ok    $1"
    else echo "  FAIL  $1"; sed 's/^/          | /' "$2"; fail=1; fi
}

# ── the channel: wrap as qm does, read as gx does ─────────────────────────
# gx's own JSON reader, cut from test-update-v3.sh, so this test reads each
# reply exactly as the rig does.
sed -n "/^    pyout=\"\$(python3 - \"\$raw\" \"\$GX_OUT\" <<'PYEOF'\$/,/^PYEOF\$/p" "$SRC" | sed '1d;$d' > "$T/gx.py"
[ -s "$T/gx.py" ] && grep -q "out-data" "$T/gx.py" || { echo "FAIL: gx's JSON reader not found in $SRC"; exit 1; }
wrap(){ # <in> <out>
    python3 - "$1" "$2" <<'PY'
import json, sys
text = open(sys.argv[1], 'rb').read().decode('latin-1')
body = json.dumps(text, ensure_ascii=False)
out = '{\n   "exitcode" : 0,\n   "exited" : 1,\n   "out-data" : %s\n}\n' % body
open(sys.argv[2], 'wb').write(out.encode('utf-8'))
PY
}
through(){ # <in> <out>: what gx leaves in GX_OUT
    wrap "$1" "$T/raw.json" && python3 "$T/gx.py" "$T/raw.json" "$2" > "$T/gx.res"
    grep -qx 'CHAN=0' "$T/gx.res" || { echo "  FAIL  the gx reader did not parse a wrapped reply"; fail=1; }
}

# ── the fixtures are the capture's ─────────────────────────────────────────
for f in manifest_step_part2.txt manifest_step_part1.txt update_plan_pull.txt pipelines_gate.toml sigmond_gate.toml pipelines_part1.toml \
         restore_part2/restore.txt restore_part2/rerun.txt restore_part2/coordination.toml \
         restore_part2/marker-v1.txt restore_part2/marker-rerun.txt; do
    [ -s "$FX/$f" ] || { echo "FAIL: fixture $f missing; run test-fixtures/sink-part2/capture.sh"; exit 1; }
done
for d in sinks-v1 sinks-restored sinks-rerun; do
    [ -s "$RP/$d/site.toml" ] || { echo "FAIL: fixture restore_part2/$d missing; run capture.sh"; exit 1; }
done
check "SOURCE names the restore capture" 1 "$(grep -c '^restore_part2/ ' "$FX/SOURCE")"
check "SOURCE names the part 1 commit" 1 "$(grep -c '^part 1 [0-9a-f]\{40\}$' "$FX/SOURCE")"
check "the capture holds client files" 2 "$(ls "$RP/sinks-v1" | grep -vcx site.toml)"

# ── guest trees and the probe ──────────────────────────────────────────────
# tree <dir> <marker 0|1> <form gate|part1> <sinks dir or -> [aside name ...]
tree(){
    local d="$1" mk="$2" form="$3" sk="$4" a; shift 4
    rm -rf "$d"; mkdir -p "$d/var/lib/hs-uploader" "$d/etc/hs-uploader/pipelines.d" "$d/etc/sigmond"
    [ "$mk" = 1 ] && cp "$RP/marker-v1.txt" "$d/var/lib/hs-uploader/carry-over-v1.done"
    for a in "$@"; do cp "$RP/marker-v1.txt" "$d/var/lib/hs-uploader/$a"; done
    : > "$d/var/lib/hs-uploader/watermarks.db"
    if [ "$form" = gate ]; then
        cp "$FX/pipelines_gate.toml" "$d/etc/hs-uploader/pipelines.toml"
        cp "$FX/sigmond_gate.toml" "$d/etc/hs-uploader/pipelines.d/sigmond.toml"
    else
        cp "$FX/pipelines_part1.toml" "$d/etc/hs-uploader/pipelines.toml"
    fi
    if [ "$sk" != - ]; then
        mkdir -p "$d/etc/hs-uploader/sinks"
        cp "$sk"/*.toml "$d/etc/hs-uploader/sinks/"
        : > "$d/etc/hs-uploader/sinks/.lock"
    fi
    cp "$RP/coordination.toml" "$d/etc/sigmond/coordination.toml"
}
# probe <tree> <out>: the real UPL_SINKS against the tree, through the channel.
probe(){ SP2U_ROOT="$1" bash -c "$UPL_SINKS" > "$T/probe.raw" 2>&1; through "$T/probe.raw" "$2"; }
# step <in> <out>: a manifest step's lines, wrapped as the rig's EB_MANIFEST
# snippet prints them (clock lines around), through the channel, reduced.
step(){
    { echo "W0:1760000000"; echo "T0:1000"; cat "$1"; echo "T1:2000"; } > "$T/step.raw"
    through "$T/step.raw" "$T/step.out"; sp2u_step_facts "$T/step.out" > "$2"
}
restore(){ through "$1" "$T/restore.out"; sp2u_restore_facts "$T/restore.out" > "$2"; }

ASIDE="carry-over-v1.done.rolled-back-20261023T120000Z"

# ── the probe itself ───────────────────────────────────────────────────────
tree "$T/e" 1 gate "$RP/sinks-v1"; probe "$T/e" "$T/e.st"
check "probe: marker"            1 "$(sp2_tok "$T/e.st" MARKER)"
check "probe: marker a file"     1 "$(sp2_tok "$T/e.st" MARKERREG)"
check "probe: heartbeat in sigmond.toml" 1 "$(sp2_tok "$T/e.st" HBSIG)"
check "probe: none in the legacy manifest" 0 "$(sp2_tok "$T/e.st" HBLEG)"
check "probe: site"              upload "$(sp2_tok "$T/e.st" SITE)"
check "probe: [uploads] wants"   upload "$(sp2_tok "$T/e.st" SITEWANT)"
check "probe: two client files, .lock and site left out" 2 "$(sp2_tok "$T/e.st" CLIENTN)"
check "probe: a CLIENT line each" 2 "$(nlines "$T/e.st" '^CLIENT|')"
check "probe: the sha is the file's" "CLIENT|psk-recorder.toml|$(sha256sum "$RP/sinks-v1/psk-recorder.toml" | cut -d' ' -f1)" \
      "$(grep '^CLIENT|psk-recorder' "$T/e.st")"
check "probe: ends with its sentinel" "SINKSDONE:1" "$(tail -1 "$T/e.st")"
tree "$T/p1" 0 part1 -; probe "$T/p1" "$T/p1.st"
check "probe: part 1 heartbeat in the legacy manifest" 1 "$(sp2_tok "$T/p1.st" HBLEG)"
check "probe: no sigmond.toml"   0 "$(sp2_tok "$T/p1.st" SIGFILE)"
check "probe: no sinks dir"      0 "$(sp2_tok "$T/p1.st" SINKSDIR)"
check "probe: no site file"      missing "$(sp2_tok "$T/p1.st" SITE)"
# [uploads] mode = "hold" (one line appended to the captured file) wants fill.
tree "$T/h" 1 gate "$RP/sinks-v1"; printf '\n[uploads]\nmode = "hold"\n' >> "$T/h/etc/sigmond/coordination.toml"
probe "$T/h" "$T/h.st"
check "probe: hold wants fill"   fill "$(sp2_tok "$T/h.st" SITEWANT)"
tree "$T/h2" 1 gate "$RP/sinks-v1"; printf '\n[uploads]\nenabled = false\n' >> "$T/h2/etc/sigmond/coordination.toml"
probe "$T/h2" "$T/h2.st"
check "probe: enabled = false wants fill" fill "$(sp2_tok "$T/h2.st" SITEWANT)"
tree "$T/h3" 1 gate "$RP/sinks-v1"; printf '\n[uploads]\nmode = "discard"\n' >> "$T/h3/etc/sigmond/coordination.toml"
probe "$T/h3" "$T/h3.st"
check "probe: discard wants off" off "$(sp2_tok "$T/h3.st" SITEWANT)"
tree "$T/a" 0 part1 "$RP/sinks-v1" "$ASIDE" "$ASIDE.1"; probe "$T/a" "$T/a.st"
check "probe: two rolled-back markers" 2 "$(sp2_tok "$T/a.st" ASIDEN)"
has   "probe: the .1 name listed" "$T/a.st" "ASIDE|$ASIDE.1"
# A crashed probe: python3 fails before its first line.
mkdir -p "$T/bin"; printf '#!/bin/sh\nexit 1\n' > "$T/bin/python3"; chmod +x "$T/bin/python3"
PATH="$T/bin:$PATH" SP2U_ROOT="$T/e" bash -c "$UPL_SINKS" > "$T/crash.raw" 2>&1; through "$T/crash.raw" "$T/crash.st"
check "probe: a crashed probe has no sentinel" "" "$(sp2_tok "$T/crash.st" SINKSDONE)"
LC_ALL=C grep -q '[^[:print:][:space:]]' <<<"$UPL_SINKS" && { echo "  FAIL  UPL_SINKS holds a byte outside printable ASCII"; fail=1; } || echo "  ok    UPL_SINKS is ASCII"
bash -n <<<"$UPL_SINKS" && echo "  ok    UPL_SINKS parses" || { echo "  FAIL  UPL_SINKS does not parse"; fail=1; }

# ── the manifest step's facts ──────────────────────────────────────────────
step "$FX/manifest_step_part2.txt" "$T/v1.f"
check "V1: features carry gate"  1 "$(sp2_tok "$T/v1.f" F_GATE)"
check "V1: carry-over lines"     7 "$(sp2_tok "$T/v1.f" CO_N)"
check "V1: first carry-over line (after W0, T0, features)" 4 "$(sp2_tok "$T/v1.f" CO_FIRST)"
check "V1: the marker line"      10 "$(sp2_tok "$T/v1.f" CO_MARKER)"
check "V1: the first render line" 11 "$(sp2_tok "$T/v1.f" RENDER_FIRST)"
check "V1: no error line"        0 "$(sp2_tok "$T/v1.f" SMDERR)"
check "V1: sentinel"             1 "$(sp2_tok "$T/v1.f" STEPFACTS)"
step "$RP/rerun.txt" "$T/rr.f"
check "rerun: carry-over lines"  4 "$(sp2_tok "$T/rr.f" CO_N)"
check "rerun: marker before render" "7 8" "$(sp2_tok "$T/rr.f" CO_MARKER) $(sp2_tok "$T/rr.f" RENDER_FIRST)"
# 'carry-over: wrote site' is no render line; an 'already current' line is.
grep -v 'pipelines.d/sigmond.toml' "$RP/rerun.txt" > "$T/rr-nosig.txt"; step "$T/rr-nosig.txt" "$T/rr2.f"
check "an 'already current' line is a render line" 8 "$(sp2_tok "$T/rr2.f" RENDER_FIRST)"
# The real error line (smd_err_line.txt, commands/uploader.py _err) counts,
# and its features text is no features line.
cat "$FX/smd_err_line.txt" "$FX/manifest_step_part2.txt" > "$T/err.txt"; step "$T/err.txt" "$T/err.f"
check "an smd: uploader: line counts" 1 "$(sp2_tok "$T/err.f" SMDERR)"
check "the features line still found" 1 "$(sp2_tok "$T/err.f" F_GATE)"
: > "$T/empty.txt"; step "$T/empty.txt" "$T/empty.f"
check "empty step: no features"  0 "$(sp2_tok "$T/empty.f" F_LINE)"
sp2u_step_facts "$T/nonexistent" > "$T/none.f"
check "an unreadable step file has no sentinel" "" "$(sp2_tok "$T/none.f" STEPFACTS)"

# ── E-bis ──────────────────────────────────────────────────────────────────
tree "$T/pre" 0 part1 -; probe "$T/pre" "$T/pre.st"
sp2u_ebis_verdict "$T/pre.st" "$T/v1.f" "$T/e.st" > "$T/v"; clean "E-bis: the V1 capture passes" "$T/v"
has   "E-bis: says the order"    "$T/v" "OK: E-bis: the carry-over ran (lines 4-10) and wrote its marker before the render (line 11)"
# Derived: the render lines moved above the carry-over (one awk).
awk '/uploader: wrote /{r = r $0 "\n"; next} {o = o $0 "\n"} /hs-uploader features/{printf "%s", o; o = ""; hold = 1} END {printf "%s%s", r, o}' \
    "$FX/manifest_step_part2.txt" > "$T/late.txt"
step "$T/late.txt" "$T/late.f"; sp2u_ebis_verdict "$T/pre.st" "$T/late.f" "$T/e.st" > "$T/v"
has   "E-bis: render first fails" "$T/v" "came before the carry-over wrote its marker"
grep -v 'carry-over:' "$FX/manifest_step_part2.txt" > "$T/noco.txt"
step "$T/noco.txt" "$T/noco.f"; sp2u_ebis_verdict "$T/pre.st" "$T/noco.f" "$T/e.st" > "$T/v"
has   "E-bis: no carry-over fails" "$T/v" "printed no 'uploader: carry-over:' line"
grep -v 'carry-over: marker written' "$FX/manifest_step_part2.txt" > "$T/nomk.txt"
step "$T/nomk.txt" "$T/nomk.f"; sp2u_ebis_verdict "$T/pre.st" "$T/nomk.f" "$T/e.st" > "$T/v"
has   "E-bis: no marker line fails" "$T/v" "printed no 'carry-over: marker written' line"
grep -v 'uploader: wrote ' "$FX/manifest_step_part2.txt" > "$T/nord.txt"
step "$T/nord.txt" "$T/nord.f"; sp2u_ebis_verdict "$T/pre.st" "$T/nord.f" "$T/e.st" > "$T/v"
has   "E-bis: no render line fails" "$T/v" "printed no render line"
sed 's/features: gate /features: /' "$FX/manifest_step_part2.txt" > "$T/nogate.txt"
step "$T/nogate.txt" "$T/nogate.f"; sp2u_ebis_verdict "$T/pre.st" "$T/nogate.f" "$T/e.st" > "$T/v"
has   "E-bis: no gate fails"     "$T/v" "offers no gate"
sed 's/uploader: carry-over: marker written/smd: uploader: carry-over: FAILED at marker: refused; no marker written, nothing enforced yet; the next manifest step tries again/' \
    "$FX/manifest_step_part2.txt" > "$T/cofail.txt"
step "$T/cofail.txt" "$T/cofail.f"; sp2u_ebis_verdict "$T/pre.st" "$T/cofail.f" "$T/e.st" > "$T/v"
has   "E-bis: a FAILED carry-over fails" "$T/v" "carry-over failure line(s)"
check "a carry-over line on stderr (smd: uploader:) is not the carry-over's own" 6 "$(sp2_tok "$T/cofail.f" CO_N)"
step "$T/err.txt" "$T/err.f"; sp2u_ebis_verdict "$T/pre.st" "$T/err.f" "$T/e.st" > "$T/v"
has   "E-bis: an error line fails" "$T/v" "'smd: uploader:' error line(s)"
tree "$T/nomarker" 0 gate "$RP/sinks-v1"; probe "$T/nomarker" "$T/nomarker.st"
sp2u_ebis_verdict "$T/pre.st" "$T/v1.f" "$T/nomarker.st" > "$T/v"
has   "E-bis: no marker on disk fails" "$T/v" "no carry-over marker"
sp2u_ebis_verdict "$T/pre.st" "$T/v1.f" "$T/h.st" > "$T/v"
has   "E-bis: site against [uploads] fails" "$T/v" "site.toml reads 'upload', but [uploads] mode = hold gives 'fill'"
tree "$T/leg" 1 part1 "$RP/sinks-v1"; probe "$T/leg" "$T/leg.st"
sp2u_ebis_verdict "$T/pre.st" "$T/v1.f" "$T/leg.st" > "$T/v"
has   "E-bis: heartbeat in the legacy manifest fails" "$T/v" "the heartbeat does not live in pipelines.d/sigmond.toml"
has   "E-bis: ... and says the legacy one holds it" "$T/v" "the legacy manifest still carries the heartbeat"
sp2u_ebis_verdict "$T/e.st" "$T/v1.f" "$T/e.st" > "$T/v"
clean "E-bis: a marker before the step is no failure" "$T/v"
has   "E-bis: ... but is said unchecked" "$T/v" "UNCHECKED: the carry-over's first run at E-bis"
# An empty reply, a crashed probe, an unreadable file: no sentinel, so no
# verdict, and nothing else is judged.
through "$T/empty.txt" "$T/empty.st"
for c in crash.st empty.st none.f; do
    sp2u_ebis_verdict "$T/pre.st" "$T/v1.f" "$T/$c" > "$T/v"
    has "E-bis: $c as the after-probe is no verdict" "$T/v" "gave no answer (not a verdict)"
    check "E-bis: $c ... and nothing else" 1 "$(nlines "$T/v" '^FAIL:')"
    sp2u_ebis_verdict "$T/$c" "$T/v1.f" "$T/e.st" > "$T/v"
    has "E-bis: $c as the before-probe is no verdict" "$T/v" "gave no answer (not a verdict)"
done
for c in crash.st none.f; do
    sp2u_ebis_verdict "$T/pre.st" "$T/$c" "$T/e.st" > "$T/v"
    has "E-bis: $c as the step facts is no verdict" "$T/v" "gave no answer (not a verdict)"
    hasnt "E-bis: $c ... and no OK line" "$T/v" "OK:"
done

# ── G-bis ──────────────────────────────────────────────────────────────────
restore "$RP/restore.txt" "$T/rs.f"
check "restore: the aside name"  "$ASIDE" "$(sp2_tok "$T/rs.f" RS_ASIDE)"
check "restore: sigmond.toml removed" 1 "$(sp2_tok "$T/rs.f" RS_RMTOML)"
check "restore: no failure"      "0 0" "$(sp2_tok "$T/rs.f" RS_MOVEFAIL) $(sp2_tok "$T/rs.f" RS_RMFAIL)"
check "restore: sentinel"        1 "$(sp2_tok "$T/rs.f" RESTFACTS)"
tree "$T/g" 0 part1 "$RP/sinks-restored" "$ASIDE"; probe "$T/g" "$T/g.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g.st" 1 > "$T/v"; clean "G-bis: the captured restore passes" "$T/v"
has   "G-bis: says the files stayed" "$T/v" "OK: G-bis: the restore left every switch file as it stood"
tree "$T/g1" 0 part1 "$RP/sinks-restored"; probe "$T/g1" "$T/g1.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g1.st" 1 > "$T/v"
has   "G-bis: the named aside missing fails" "$T/v" "but no such file stands"
has   "G-bis: ... and no new aside" "$T/v" "no new rolled-back marker"
tree "$T/g2" 1 part1 "$RP/sinks-restored" "$ASIDE"; probe "$T/g2" "$T/g2.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g2.st" 1 > "$T/v"
has   "G-bis: a marker still standing fails" "$T/v" "the carry-over marker still stands"
tree "$T/g3" 0 gate "$RP/sinks-restored" "$ASIDE"; probe "$T/g3" "$T/g3.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g3.st" 1 > "$T/v"
has   "G-bis: sigmond.toml left fails" "$T/v" "pipelines.d/sigmond.toml still stands"
has   "G-bis: ... no heartbeat in the legacy manifest" "$T/v" "the legacy manifest carries no heartbeat"
# Derived: one history entry appended to a client file at G-bis.
tree "$T/g4" 0 part1 "$RP/sinks-restored" "$ASIDE"
printf '\n[[history]]\nat = "2026-10-23T12:00:00Z"\nfrom = "upload"\nto = "upload"\nby = "x"\nreason = ""\n' >> "$T/g4/etc/hs-uploader/sinks/wspr-recorder.toml"
probe "$T/g4" "$T/g4.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g4.st" 1 > "$T/v"
has   "G-bis: a switch file changed by the restore fails" "$T/v" "the restore changed switch files: changed wspr-recorder.toml"
tree "$T/g5" 0 part1 "$RP/sinks-restored" "$ASIDE"; rm "$T/g5/etc/hs-uploader/sinks/site.toml"; probe "$T/g5" "$T/g5.st"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g5.st" 1 > "$T/v"
has   "G-bis: site.toml gone fails" "$T/v" "gone site.toml"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/g.st" 0 > "$T/v"
clean "G-bis: restore that kept sigmond is no failure" "$T/v"
has   "G-bis: ... but is said unchecked" "$T/v" "UNCHECKED: the restore's marker move"
sed "s/$ASIDE;/$ASIDE.1;/" "$RP/restore.txt" > "$T/r1.txt"; restore "$T/r1.txt" "$T/r1.f"
tree "$T/g6" 0 part1 "$RP/sinks-restored" "$ASIDE" "$ASIDE.1"; probe "$T/g6" "$T/g6.st"
sp2u_gbis_verdict "$T/e.st" "$T/r1.f" "$T/g6.st" 1 > "$T/v"
clean "G-bis: a .1 name (the first taken) passes" "$T/v"
grep -v 'moved the carry-over marker aside' "$RP/restore.txt" > "$T/r2.txt"; restore "$T/r2.txt" "$T/r2.f"
sp2u_gbis_verdict "$T/e.st" "$T/r2.f" "$T/g.st" 1 > "$T/v"
has   "G-bis: no move line fails" "$T/v" "printed no 'moved the carry-over marker aside to' line"
grep -v 'pipelines.d/sigmond.toml: the restored' "$RP/restore.txt" > "$T/r3.txt"; restore "$T/r3.txt" "$T/r3.f"
sp2u_gbis_verdict "$T/e.st" "$T/r3.f" "$T/g.st" 1 > "$T/v"
has   "G-bis: no removal line fails" "$T/v" "printed no 'removed .../pipelines.d/sigmond.toml' line"
# E-bis already had that aside: the count did not rise.
tree "$T/e2" 1 gate "$RP/sinks-v1" "$ASIDE"; probe "$T/e2" "$T/e2.st"
sp2u_gbis_verdict "$T/e2.st" "$T/rs.f" "$T/g.st" 1 > "$T/v"
has   "G-bis: no new aside fails" "$T/v" "no new rolled-back marker (E-bis 1, G-bis 1)"
sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/h.st" 1 > "$T/v"
has   "G-bis: [uploads] no longer matching fails" "$T/v" "site.toml reads 'upload', but [uploads] mode = hold gives 'fill'"
for c in crash.st empty.st; do
    sp2u_gbis_verdict "$T/e.st" "$T/rs.f" "$T/$c" 1 > "$T/v"
    has "G-bis: $c as the probe is no verdict" "$T/v" "gave no answer (not a verdict)"
    check "G-bis: $c ... and nothing else" 1 "$(nlines "$T/v" '^FAIL:')"
done
sp2u_gbis_verdict "$T/e.st" "$T/none.f" "$T/g.st" 1 > "$T/v"
has   "G-bis: no restore facts is no verdict" "$T/v" "the restore's facts gave no answer"


# ── the restore's moved checkouts ─────────────────────────────────────────
through "$RP/restore.txt" "$T/rs0.out"; sp2u_moved "$T/rs0.out" > "$T/mv.f"
check "moved: sigmond, by its own line" "MOVED|sigmond|aaaaaaa" "$(grep '^MOVED|' "$T/mv.f")"
check "moved: sentinel"          1 "$(sp2_tok "$T/mv.f" MOVEDDONE)"
# A look-alike name ahead of ": checked out" is not sigmond (one line edited).
sed 's/  sigmond: checked out/  hs-sigmond: checked out/' "$RP/restore.txt" > "$T/lk.txt"; through "$T/lk.txt" "$T/lk.out"
sp2u_moved "$T/lk.out" > "$T/lk.f"
check "moved: hs-sigmond is not sigmond" "MOVED|hs-sigmond|aaaaaaa" "$(grep '^MOVED|' "$T/lk.f")"
# hs-uploader moved too: the sigmond line repeated under its name.
awk '{print} /sigmond: checked out/ {l = $0; sub(/sigmond: checked out aaaaaaa/, "hs-uploader: checked out bbbbbbb", l); print l}' \
    "$RP/restore.txt" > "$T/r2c.txt"; through "$T/r2c.txt" "$T/r2c.out"; sp2u_moved "$T/r2c.out" > "$T/mv2.f"
check "moved: both"              2 "$(nlines "$T/mv2.f" '^MOVED|')"
grep -v 'checked out' "$RP/restore.txt" > "$T/r0.txt"; through "$T/r0.txt" "$T/r0.out"; sp2u_moved "$T/r0.out" > "$T/mv0.f"
check "moved: none"              0 "$(nlines "$T/mv0.f" '^MOVED|')"
sp2u_moved "$T/nonexistent" > "$T/mvx.f"
check "moved: an unreadable file has no sentinel" "" "$(sp2_tok "$T/mvx.f" MOVEDDONE)"

# ── the second update's facts ─────────────────────────────────────────────
# update_plan_pull.txt: bin/smd's own plan lines for sigmond and hs-uploader
# one commit behind (the --apply run prints the same lines ahead of each step).
through "$FX/update_plan_pull.txt" "$T/up.out"
sp2u_update_facts "$T/up.out" "$T/mv2.f" > "$T/up2.f"
check "update: both moved and both pulled" "1 1 1 1" "$(for k in MOVED_SIG PULL_SIG MOVED_HSU PULL_HSU; do printf '%s ' "$(sp2_tok "$T/up2.f" $k)"; done | sed 's/ $//')"
sp2u_update_facts "$T/up.out" "$T/mv.f" > "$T/up1.f"
check "update: sigmond alone moved" "1 0" "$(sp2_tok "$T/up1.f" MOVED_SIG) $(sp2_tok "$T/up1.f" MOVED_HSU)"
grep -v '\[pull\] sigmond' "$T/up.out" > "$T/up-nosig.out"; sp2u_update_facts "$T/up-nosig.out" "$T/mv2.f" > "$T/upns.f"
check "update: no sigmond pull"  0 "$(sp2_tok "$T/upns.f" PULL_SIG)"
grep -v '\[pull\] hs-uploader' "$T/up.out" > "$T/up-nohsu.out"; sp2u_update_facts "$T/up-nohsu.out" "$T/mv2.f" > "$T/upnh.f"
check "update: no hs-uploader pull" 0 "$(sp2_tok "$T/upnh.f" PULL_HSU)"
sed 's/\[pull\] sigmond/[pull] sigmond-extra/' "$T/up.out" > "$T/up-lk.out"; sp2u_update_facts "$T/up-lk.out" "$T/mv2.f" > "$T/uplk.f"
check "update: [pull] sigmond-extra is not sigmond" 0 "$(sp2_tok "$T/uplk.f" PULL_SIG)"
sp2u_update_facts "$T/up.out" "$T/mvx.f" > "$T/upx.f"
check "update: no moved facts, no sentinel" "" "$(sp2_tok "$T/upx.f" UPDFACTS)"
sp2u_update_facts "$T/up.out" "$T/mv0.f" > "$T/up0.f"

# ── the re-attach (G-ter step 0) ──────────────────────────────────────────
# A real git: origin with two commits, a checkout under the scratch root on
# main, the branch probe at E, then the restore's detach to the first commit.
# runuser is stood in by a script that drops "-u <user> --"; stat is real,
# so the owner is this account (never root here).
cat > "$T/bin/runuser" <<'X'
#!/bin/sh
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
X
chmod +x "$T/bin/runuser"
gitq(){ git -c user.email=t@example -c user.name=t -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
G="$T/git"; mkdir -p "$G"
gitq init --bare -b main "$G/origin.git"
gitq clone "$G/origin.git" "$G/seed"
echo a > "$G/seed/a"; gitq -C "$G/seed" add -A; gitq -C "$G/seed" commit -m one; gitq -C "$G/seed" push -u origin main
A="$(git -C "$G/seed" rev-parse HEAD)"
echo b > "$G/seed/b"; gitq -C "$G/seed" add -A; gitq -C "$G/seed" commit -m two; gitq -C "$G/seed" push origin main
R="$T/rt"; mkdir -p "$R/opt/git/sigmond"
gitq clone "$G/origin.git" "$R/opt/git/sigmond/sigmond"
gitq clone "$G/origin.git" "$R/opt/git/sigmond/hs-uploader"
gitq clone "$G/origin.git" "$R/opt/git/sigmond/ka9q-radio"; gitq -C "$R/opt/git/sigmond/ka9q-radio" checkout --detach "$A"
mkdir -p "$R/opt/git/sigmond/notarepo"
RUN=(env SP2U_ROOT="$R" SP2U_RUNUSER="$T/bin/runuser")
"${RUN[@]}" bash -c "$UPL_BRANCHES" > "$T/br.raw" 2>&1; through "$T/br.raw" "$T/br.out"
me="$(id -un)"
has   "branches: sigmond on main"      "$T/br.out" "BRANCH|sigmond|main|$me"
has   "branches: a detached one reads -" "$T/br.out" "BRANCH|ka9q-radio|-|$me"
check "branches: only git checkouts"   3 "$(nlines "$T/br.out" '^BRANCH|')"
check "branches: sentinel"             1 "$(sp2_tok "$T/br.out" BRANCHDONE)"
LC_ALL=C grep -q '[^[:print:][:space:]]' <<<"$UPL_BRANCHES" && { echo "  FAIL  UPL_BRANCHES holds a byte outside printable ASCII"; fail=1; } || echo "  ok    UPL_BRANCHES is ASCII"
# The restore detaches both at the first commit; its lines name that SHA
# (the captured lines, the SHA edited in).
short="${A:0:7}"
for c in sigmond hs-uploader; do gitq -C "$R/opt/git/sigmond/$c" checkout --detach "$A"; done
sed "s/aaaaaaa/$short/; s/bbbbbbb/$short/" "$T/r2c.txt" > "$T/rg.txt"; through "$T/rg.txt" "$T/rg.out"; sp2u_moved "$T/rg.out" > "$T/mvg.f"
sp2u_reattach_plan "$T/mvg.f" "$T/br.out" > "$T/plan"
check "plan: both, onto main, at the restored SHA" "PLAN|sigmond|main|$short PLAN|hs-uploader|main|$short" "$(grep '^PLAN|' "$T/plan" | sort -r | tr '\n' ' ' | sed 's/ $//')"
check "plan: sentinel"           1 "$(sp2_tok "$T/plan" PLANDONE)"
sp2u_reattach_script "$T/plan" > "$T/ra.sh"
bash -n "$T/ra.sh" && echo "  ok    the re-attach script parses" || { echo "  FAIL  the re-attach script does not parse"; fail=1; }
LC_ALL=C grep -q '[^[:print:][:space:]]' "$T/ra.sh" && { echo "  FAIL  the re-attach script holds a byte outside printable ASCII"; fail=1; } || echo "  ok    the re-attach script is ASCII"
"${RUN[@]}" bash "$T/ra.sh" > "$T/ra.raw" 2>&1; through "$T/ra.raw" "$T/ra.out"
check "re-attach: sigmond on main again" "main" "$(git -C "$R/opt/git/sigmond/sigmond" symbolic-ref -q --short HEAD)"
check "re-attach: at the restored commit" "$A" "$(git -C "$R/opt/git/sigmond/sigmond" rev-parse HEAD)"
check "re-attach: one commit behind its upstream" 1 "$(git -C "$R/opt/git/sigmond/sigmond" rev-list --count 'HEAD..@{u}')"
sp2u_reattach_verdict "$T/plan" "$T/ra.out" > "$T/v"; clean "re-attach: the real git passes" "$T/v"
has   "re-attach: says so"       "$T/v" "OK: G-ter re-attach: sigmond back on main at $short (as $me, tracking origin/main)"
check "re-attach: one OK per checkout" 2 "$(nlines "$T/v" '^OK:')"
# A checkout root owns is refused, never run as root (stat stood in).
printf '#!/bin/sh\necho root\n' > "$T/bin/stat-root"; chmod +x "$T/bin/stat-root"
SP2U_STAT="$T/bin/stat-root" "${RUN[@]}" bash "$T/ra.sh" > "$T/rr.raw" 2>&1; through "$T/rr.raw" "$T/rro.out"
sp2u_reattach_verdict "$T/plan" "$T/rro.out" > "$T/v"
has   "re-attach: root-owned is refused" "$T/v" "the rig never runs git there as root"
# A SHA the checkout lacks: git checkout fails.
sed "s/|$short\$/|deadbee/" "$T/plan" > "$T/plan-bad"; sp2u_reattach_script "$T/plan-bad" > "$T/ra-bad.sh"
"${RUN[@]}" bash "$T/ra-bad.sh" > "$T/rb.raw" 2>&1; through "$T/rb.raw" "$T/rb.out"
sp2u_reattach_verdict "$T/plan-bad" "$T/rb.out" > "$T/v"
has   "re-attach: a failed checkout fails" "$T/v" "git checkout -B main deadbee in sigmond exited"
# A branch with no upstream: smd update could not pull it.
gitq -C "$R/opt/git/sigmond/sigmond" checkout --detach "$A"; gitq -C "$R/opt/git/sigmond/sigmond" branch --unset-upstream main
"${RUN[@]}" bash "$T/ra.sh" > "$T/ru.raw" 2>&1; through "$T/ru.raw" "$T/ru.out"
sp2u_reattach_verdict "$T/plan" "$T/ru.out" > "$T/v"
has   "re-attach: no upstream fails" "$T/v" "sigmond's branch main tracks no upstream"
# The guest's answer edited: another branch, another HEAD.
sed "s/^REATTACH|sigmond|main|\([^|]*\)|0|main|/REATTACH|sigmond|main|\1|0|other|/" "$T/ra.out" > "$T/ra-o.out"
sp2u_reattach_verdict "$T/plan" "$T/ra-o.out" > "$T/v"
has   "re-attach: the wrong branch fails" "$T/v" "sigmond sits on 'other' after the checkout"
sed "s/^\(REATTACH|sigmond|main|[^|]*|0|main|\)$A|/\1$(git -C "$G/seed" rev-parse HEAD)|/" "$T/ra.out" > "$T/ra-h.out"
sp2u_reattach_verdict "$T/plan" "$T/ra-h.out" > "$T/v"
has   "re-attach: the wrong HEAD fails" "$T/v" "sigmond's HEAD reads"
grep -v '^REATTACH|hs-uploader|' "$T/ra.out" > "$T/ra-m.out"
sp2u_reattach_verdict "$T/plan" "$T/ra-m.out" > "$T/v"
has   "re-attach: a missing answer fails" "$T/v" "the guest gave no answer for hs-uploader"
grep -v 'REATTACHDONE' "$T/ra.out" > "$T/ra-x.out"
sp2u_reattach_verdict "$T/plan" "$T/ra-x.out" > "$T/v"
has   "re-attach: no sentinel is no verdict" "$T/v" "G-ter re-attach: the guest gave no answer (not a verdict)"
hasnt "re-attach: ... and no OK line" "$T/v" "OK:"
# Plans that cannot be made.
grep -v '^BRANCH|hs-uploader|' "$T/br.out" > "$T/br-m.out"; sp2u_reattach_plan "$T/mvg.f" "$T/br-m.out" > "$T/p-m"
has   "plan: no recorded branch fails" "$T/p-m" "no branch recorded at E for hs-uploader"
sed 's/^BRANCH|sigmond|main|/BRANCH|sigmond|-|/' "$T/br.out" > "$T/br-d.out"; sp2u_reattach_plan "$T/mvg.f" "$T/br-d.out" > "$T/p-d"
has   "plan: detached at E fails" "$T/p-d" "sigmond sat detached at E"
# A pinned checkout the restore moved (ka9q-radio sat detached at E): said
# unchecked, never a failure.
sed 's/sigmond: checked out aaaaaaa/ka9q-radio: checked out aaaaaaa/' "$RP/restore.txt" > "$T/rk.txt"; through "$T/rk.txt" "$T/rk.out"
sp2u_moved "$T/rk.out" > "$T/mvk.f"; sp2u_reattach_plan "$T/mvk.f" "$T/br.out" > "$T/p-k"
has   "plan: a pinned checkout is said unchecked" "$T/p-k" "UNCHECKED: G-ter re-attach of ka9q-radio"
hasnt "plan: ... not failed" "$T/p-k" "FAIL:"
sp2u_reattach_script "$T/p-k" > "$T/rak.sh"; "${RUN[@]}" bash "$T/rak.sh" > "$T/rk.raw" 2>&1; through "$T/rk.raw" "$T/rko.out"
sp2u_reattach_verdict "$T/p-k" "$T/rko.out" > "$T/v"
clean "re-attach: a pinned checkout alone is no failure" "$T/v"
has   "re-attach: ... and the verdict says it" "$T/v" "UNCHECKED: G-ter re-attach of ka9q-radio"
sed 's/^BRANCH|sigmond|main|/BRANCH|sigmond|-x;rm|/' "$T/br.out" > "$T/br-q.out"; sp2u_reattach_plan "$T/mvg.f" "$T/br-q.out" > "$T/p-q"
has   "plan: an odd branch is refused" "$T/p-q" "refusing an odd name, branch or SHA"
sp2u_reattach_verdict "$T/p-d" "$T/ra.out" > "$T/v"
has   "re-attach: a plan FAIL carries into the verdict" "$T/v" "sigmond sat detached at E"
grep -v BRANCHDONE "$T/br.out" > "$T/br-x.out"; sp2u_reattach_plan "$T/mvg.f" "$T/br-x.out" > "$T/p-x"
has   "plan: unanswered branches are no verdict" "$T/p-x" "the branches recorded at E gave no answer (not a verdict)"
sp2u_reattach_plan "$T/mv0.f" "$T/br.out" > "$T/p-0"; sp2u_reattach_script "$T/p-0" > "$T/ra0.sh"
"${RUN[@]}" bash "$T/ra0.sh" > "$T/r0.raw" 2>&1; through "$T/r0.raw" "$T/r0x.out"
sp2u_reattach_verdict "$T/p-0" "$T/r0x.out" > "$T/v"
clean "re-attach: nothing moved is no failure" "$T/v"
has   "re-attach: ... but is said unchecked" "$T/v" "UNCHECKED: the re-attach before the second update"

# ── G-ter ──────────────────────────────────────────────────────────────────
tree "$T/t" 1 gate "$RP/sinks-rerun" "$ASIDE"; probe "$T/t" "$T/t.st"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t.st" "$T/up2.f" > "$T/v"; clean "G-ter: the captured rerun passes" "$T/v"
has   "G-ter: says the client files stood" "$T/v" "OK: G-ter: all 2 client switch file(s) stand byte for byte as at G-bis"
has   "G-ter: says the carry-over ran again" "$T/v" "OK: G-ter: the carry-over ran (lines 4-7) and wrote its marker before the render (line 8)"
# The mutation's target: a client file whose [[history]] gained an entry
# (one entry appended to the captured file).
tree "$T/t1" 1 gate "$RP/sinks-rerun" "$ASIDE"
printf '\n[[history]]\nat = "2026-10-23T12:00:00Z"\nfrom = "upload"\nto = "upload"\nby = "carry-over"\nreason = "carried over from [uploads] mode = upload"\n' \
    >> "$T/t1/etc/hs-uploader/sinks/psk-recorder.toml"
probe "$T/t1" "$T/t1.st"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t1.st" "$T/up2.f" > "$T/v"
has   "G-ter: a changed client file fails" "$T/v" "FAIL: G-ter: client switch files changed across the second update: changed psk-recorder.toml"
tree "$T/t2" 1 gate "$RP/sinks-rerun" "$ASIDE"; rm "$T/t2/etc/hs-uploader/sinks/wspr-recorder.toml"; probe "$T/t2" "$T/t2.st"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t2.st" "$T/up2.f" > "$T/v"
has   "G-ter: a client file gone fails" "$T/v" "changed across the second update: gone wspr-recorder.toml"
hasnt "G-ter: ... with no word of an added file" "$T/v" "an added file means"
tree "$T/t3" 1 gate "$RP/sinks-rerun" "$ASIDE"
sed 's/^client = "wspr-recorder"$/client = "meteor-scatter"/' "$RP/sinks-rerun/wspr-recorder.toml" > "$T/t3/etc/hs-uploader/sinks/meteor-scatter.toml"
probe "$T/t3" "$T/t3.st"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t3.st" "$T/up2.f" > "$T/v"
has   "G-ter: a client file added fails" "$T/v" "changed across the second update: added meteor-scatter.toml"
has   "G-ter: ... naming the likely cause" "$T/v" "an added file means the second step wrote a switch file for a client that had none at G-bis"
# A switch file that is a symlink: a change of target is a change.
tree "$T/gl" 0 part1 "$RP/sinks-restored" "$ASIDE"
mv "$T/gl/etc/hs-uploader/sinks/psk-recorder.toml" "$T/gl/psk-a.toml"; cp "$T/gl/psk-a.toml" "$T/gl/psk-b.toml"
ln -s "$T/gl/psk-a.toml" "$T/gl/etc/hs-uploader/sinks/psk-recorder.toml"; probe "$T/gl" "$T/gl.st"
check "probe: a symlink records its target" "CLIENT|psk-recorder.toml|link:$T/gl/psk-a.toml" "$(grep '^CLIENT|psk-recorder' "$T/gl.st")"
ln -sfn "$T/gl/psk-b.toml" "$T/gl/etc/hs-uploader/sinks/psk-recorder.toml"; probe "$T/gl" "$T/gl2.st"
sp2u_gter_verdict "$T/gl.st" "$T/rr.f" "$T/gl2.st" "$T/up2.f" > "$T/v"
has   "G-ter: a symlink pointed elsewhere fails" "$T/v" "changed psk-recorder.toml"
# The CARRY-OVER GATE: a client file present at G-bis that E-bis never had
# (mag-recorder's, derived from the captured wspr-recorder file) is covered:
# when it changes at G-ter, G-ter fails.  The verdict takes no E-bis input.
tree "$T/gm" 0 part1 "$RP/sinks-restored" "$ASIDE"
sed 's/^client = "wspr-recorder"$/client = "mag-recorder"/' "$RP/sinks-restored/wspr-recorder.toml" > "$T/gm/etc/hs-uploader/sinks/mag-recorder.toml"
probe "$T/gm" "$T/gm.st"
tree "$T/tm" 1 gate "$RP/sinks-rerun" "$ASIDE"
{ sed 's/^client = "wspr-recorder"$/client = "mag-recorder"/' "$RP/sinks-rerun/wspr-recorder.toml"
  printf '\n[[history]]\nat = "2026-10-23T12:00:00Z"\nfrom = "upload"\nto = "fill"\nby = "x"\nreason = ""\n'; } \
    > "$T/tm/etc/hs-uploader/sinks/mag-recorder.toml"
probe "$T/tm" "$T/tm.st"
check "G-ter: E-bis lacked mag-recorder's file" 0 "$(grep -c '^CLIENT|mag-recorder' "$T/e.st")"
sp2u_gter_verdict "$T/gm.st" "$T/rr.f" "$T/tm.st" "$T/up2.f" > "$T/v"
has   "G-ter: a file new since E-bis that changed fails" "$T/v" "changed mag-recorder.toml"
tree "$T/tm2" 1 gate "$RP/sinks-rerun" "$ASIDE"
sed 's/^client = "wspr-recorder"$/client = "mag-recorder"/' "$RP/sinks-rerun/wspr-recorder.toml" > "$T/tm2/etc/hs-uploader/sinks/mag-recorder.toml"
probe "$T/tm2" "$T/tm2.st"
sp2u_gter_verdict "$T/gm.st" "$T/rr.f" "$T/tm2.st" "$T/up2.f" > "$T/v"
clean "G-ter: ... and passes unchanged" "$T/v"
has   "G-ter: ... counting all three" "$T/v" "all 3 client switch file(s)"
tree "$T/t4" 0 gate "$RP/sinks-rerun" "$ASIDE"; probe "$T/t4" "$T/t4.st"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t4.st" "$T/up2.f" > "$T/v"
has   "G-ter: no marker after the rerun fails" "$T/v" "no carry-over marker"
grep -v 'carry-over:' "$RP/rerun.txt" > "$T/rr-noco.txt"; step "$T/rr-noco.txt" "$T/rr-noco.f"
sp2u_gter_verdict "$T/g.st" "$T/rr-noco.f" "$T/t.st" "$T/up2.f" > "$T/v"
has   "G-ter: gate but no carry-over fails" "$T/v" "printed no 'uploader: carry-over:' line"
# The restored release's own step: part 1's manifest step, captured
# (manifest_step_part1.txt): a features line without gate, no carry-over.
step "$FX/manifest_step_part1.txt" "$T/old.f"
check "part 1's step: a features line" "1 0 0" "$(sp2_tok "$T/old.f" F_LINE) $(sp2_tok "$T/old.f" F_GATE) $(sp2_tok "$T/old.f" CO_N)"
tree "$T/t5" 0 part1 "$RP/sinks-rerun" "$ASIDE"; probe "$T/t5" "$T/t5.st"
sp2u_gter_verdict "$T/g.st" "$T/old.f" "$T/t5.st" "$T/upns.f" > "$T/v"
has   "G-ter: the restored sigmond left in place fails" "$T/v" "FAIL: G-ter: the second update planned no '[pull] sigmond': the restored sigmond stayed in place"
has   "G-ter: ... and the files still compared" "$T/v" "OK: G-ter: all 2 client switch file(s)"
sp2u_gter_verdict "$T/g.st" "$T/old.f" "$T/t5.st" "$T/up2.f" > "$T/v"
has   "G-ter: pulled, yet the old step ran, fails" "$T/v" "the second manifest step's hs-uploader offers no gate"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t.st" "$T/upnh.f" > "$T/v"
has   "G-ter: hs-uploader moved but not pulled fails" "$T/v" "planned no '[pull] hs-uploader'"
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t.st" "$T/up1.f" > "$T/v"
clean "G-ter: hs-uploader not moved needs no pull" "$T/v"
sed 's/features: gate /features: /' "$RP/rerun.txt" > "$T/rr-ng.txt"; step "$T/rr-ng.txt" "$T/rr-ng.f"
sp2u_gter_verdict "$T/g.st" "$T/rr-ng.f" "$T/t5.st" "$T/up2.f" > "$T/v"
has   "G-ter: no gate after the pulls fails" "$T/v" "FAIL: G-ter: the second manifest step's hs-uploader offers no gate"
sp2u_gter_verdict "$T/g.st" "$T/old.f" "$T/t5.st" "$T/up0.f" > "$T/v"
clean "G-ter: a restore that moved nothing is no failure" "$T/v"
has   "G-ter: ... but is said unchecked" "$T/v" "UNCHECKED: the carry-over's second run (the restore moved no sigmond"
sp2u_gter_verdict "$T/p1.st" "$T/old.f" "$T/p1.st" "$T/up0.f" > "$T/v"
has   "G-ter: no client file anywhere is said unchecked" "$T/v" "UNCHECKED: every client switch file kept"
for c in crash.st empty.st; do
    sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/$c" "$T/up2.f" > "$T/v"
    has "G-ter: $c as the probe is no verdict" "$T/v" "gave no answer (not a verdict)"
    hasnt "G-ter: $c ... and no OK line" "$T/v" "OK:"
    sp2u_gter_verdict "$T/$c" "$T/rr.f" "$T/t.st" "$T/up2.f" > "$T/v"
    has "G-ter: $c as the G-bis probe is no verdict" "$T/v" "gave no answer (not a verdict)"
done
sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t.st" "$T/upx.f" > "$T/v"
has   "G-ter: no update facts is no verdict" "$T/v" "the second update's facts gave no answer"
check "the comparison ends with its sentinel" "DIFFDONE:1" "$(sp2u_sum_diff "$T/g.st" "$T/t.st" CLIENT | tail -1)"

# ── a verdict with no finding is no verdict ───────────────────────────────
_sp2u_finish true > "$T/v"
check "finish: a body that printed nothing gets no sentinel" "" "$(cat "$T/v")"
_sp2u_finish _sp2u_no_such_body > "$T/v"
hasnt "finish: a missing body gets no sentinel" "$T/v" "VERDICT:done"
( unset -f _sp2u_gter; sp2u_gter_verdict "$T/g.st" "$T/rr.f" "$T/t.st" "$T/up2.f" ) > "$T/v"
hasnt "finish: G-ter with its body unset gets no sentinel" "$T/v" "VERDICT:done"

# ── sp2u_report ────────────────────────────────────────────────────────────
say(){ echo "SAY $*"; }
fatal(){ echo "FATAL $2"; exit 1; }
printf 'OK: a\nUNCHECKED: b\nVERDICT:done\n' > "$T/rv"
( SINK2_UNCHECKED=""; sp2u_report "$T/rv" "$T/rv" X; echo "RC0 [$SINK2_UNCHECKED]" ) > "$T/rep" 2>&1
has   "report: OK said"          "$T/rep" "SAY a ✓"
has   "report: UNCHECKED kept"   "$T/rep" "RC0 [b]"
printf 'UNCHECKED: b\nFAIL: c\nVERDICT:done\n' > "$T/rv"
( sp2u_report "$T/rv" "$T/rv" X; echo "RETURNED" ) > "$T/rep" 2>&1
has   "report: a FAIL is fatal"  "$T/rep" "FATAL X: 1 sink switch finding(s) above"
hasnt "report: ... and stops"    "$T/rep" "RETURNED"
printf 'OK: a\n' > "$T/rv"
( sp2u_report "$T/rv" "$T/rv" X; echo "RETURNED" ) > "$T/rep" 2>&1
has   "report: no VERDICT:done is no verdict" "$T/rep" "FATAL X: the sink switch verdict did not finish"
( sp2u_report "$T/missing" "$T/rv" X; echo "RETURNED" ) > "$T/rep" 2>&1
has   "report: a missing verdict is no verdict" "$T/rep" "did not finish"
printf 'VERDICT:done\n' > "$T/rv"
( sp2u_report "$T/rv" "$T/rv" X; echo "RETURNED" ) > "$T/rep" 2>&1
has   "report: a sentinel with no finding is no verdict" "$T/rep" "FATAL X: the sink switch verdict holds no finding"

# ── the rig wires them ─────────────────────────────────────────────────────
for w in 'sp2u_ebis_verdict "$WORK/eb0-sinks-pre.out" "$WORK/eb1-sink.facts" "$WORK/eb1-sinks.out" > "$WORK/eb1-sink.verdict"' \
         'sp2u_report "$WORK/eb1-sink.verdict" "$WORK/eb1-manifest.out" "E-bis"' \
         'sp2u_moved "$WORK/g3-restore-apply.out" > "$WORK/g3-moved.facts"' \
         'grep -q '\''^MOVED|sigmond|'\'' "$WORK/g3-moved.facts" && GB_SIGMOVED=1' \
         'sp2u_gbis_verdict "$WORK/eb1-sinks.out" "$WORK/gb0-restore.facts" "$WORK/gb0-sinks.out" "$GB_SIGMOVED" > "$WORK/gb0-sink.verdict"' \
         'sp2u_report "$WORK/gb0-sink.verdict" "$WORK/g3-restore-apply.out" "G-bis"' \
         'gx_ok 120 e9-branches "$UPL_BRANCHES" "the branch each checkout sits on"' \
         'sp2u_reattach_plan "$WORK/g3-moved.facts" "$WORK/branches-at-e.txt" > "$WORK/gt0-reattach.plan"' \
         'gx_ok 300 gt0-reattach "$(sp2u_reattach_script "$WORK/gt0-reattach.plan")" "G-ter: re-attach the restored checkouts"' \
         'sp2u_reattach_verdict "$WORK/gt0-reattach.plan" "$WORK/gt0-reattach.out" > "$WORK/gt0-reattach.verdict"' \
         'sp2u_report "$WORK/gt0-reattach.verdict" "$WORK/gt0-reattach.out" "G-ter re-attach"' \
         'sp2u_update_facts "$WORK/gt1-update-apply.out" "$WORK/g3-moved.facts" > "$WORK/gt1-update.facts"' \
         'sp2u_gter_verdict "$WORK/gb0-sinks.out" "$WORK/gt2-sink.facts" "$WORK/gt2-sinks.out" "$WORK/gt1-update.facts" > "$WORK/gt2-sink.verdict"' \
         'sp2u_report "$WORK/gt2-sink.verdict" "$WORK/gt2-manifest.out" "G-ter"'; do
    check "the rig runs: ${w:0:60}" 1 "$(grep -cxF -- "$w" "$SRC")"
done
check "the closing line names what went unchecked" 1 "$(grep -cxF -- '    say "⚠ SINK SWITCHES NOT EVALUATED: $SINK2_UNCHECKED"' "$SRC")"
check "no bare 'sigmond: checked out' grep remains" 0 "$(grep -c "grep -q 'sigmond: checked out'" "$SRC")"
# Each probe runs after the step it judges, and the loader runs at startup.
ln(){ grep -nF -- "$1" "$SRC" | head -1 | cut -d: -f1; }
[ "$(ln 'gx_ok 900 eb1-manifest')" -lt "$(ln 'gx_ok 120 eb1-sinks')" ] && [ "$(ln 'gx_ok 120 eb0-sinks-pre')" -lt "$(ln 'gx_ok 900 eb1-manifest')" ] \
    && echo "  ok    E-bis probes before and after the step" || { echo "  FAIL  E-bis probe order"; fail=1; }
[ "$(ln 'gx_ok 1800 g3-restore-apply')" -lt "$(ln 'gx_ok 120 gb0-sinks')" ] \
    && echo "  ok    G-bis probes after the restore" || { echo "  FAIL  G-bis probe order"; fail=1; }
[ "$(ln 'gx_ok 1800 g3-restore-apply')" -lt "$(ln 'gx_ok 300 gt0-reattach')" ] && [ "$(ln 'gx_ok 300 gt0-reattach')" -lt "$(ln 'gx_ok 3600 gt1-update-apply')" ] \
    && echo "  ok    the re-attach runs after the restore and before the second update" || { echo "  FAIL  re-attach order"; fail=1; }
[ "$(ln 'gx_ok 120 e9-branches')" -lt "$(ln 'gx_ok 1800 g3-restore-apply')" ] \
    && echo "  ok    the branches are recorded before the restore" || { echo "  FAIL  branch probe order"; fail=1; }
[ "$(ln 'gx_ok 900 gt2-manifest')" -lt "$(ln 'gx_ok 120 gt2-sinks')" ] \
    && echo "  ok    G-ter probes after the second step" || { echo "  FAIL  G-ter probe order"; fail=1; }
[ "$(ln "type sp2_tok >/dev/null 2>&1")" -lt "$(ln '# >>> sink2b_update')" ] && [ "$(ln "type sp2_tok >/dev/null 2>&1")" -lt "$(ln 'resolve_ssh(){')" ] \
    && echo "  ok    sp2_tok is checked at startup" || { echo "  FAIL  sp2_tok is not checked at startup"; fail=1; }

if [ "$fail" = 0 ]; then echo "PASS: sink2b_update"; else exit 1; fi
