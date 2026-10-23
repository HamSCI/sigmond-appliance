#!/bin/bash
# test-nested-sink-part2.sh — the readers in test-nested-v3.sh's sink_part2
# block (sigmond step 2b part 2: the switch files, the marker and the levers),
# fed real output.  No VM, no root.
#
#   usage: ./test-nested-sink-part2.sh [path/to/test-nested-v3.sh]
#
# Input comes from test-fixtures/sink-part2/, which capture.sh there copies
# and renders from one sigmond commit (named in its SOURCE file):
#   test-fixtures/sink-part2/capture.sh ../sigmond <commit>
# Every guest reply passes through wrap(), which builds what `qm guest exec`
# hands back: one JSON object whose "out-data" line holds every output line,
# and each byte above 0x7F of the guest's output turned into its own
# character, so a UTF-8 sign arrives double-encoded.
#
# The probe script itself runs here against a scratch tree built from the
# rendered files, with smd and hs-uploader stood in by scripts that print
# the captured output.  Lines typed below are the rig's own probe format
# (PLANTED|, UNIT|, ...), never a program's output.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/test-nested-v3.sh}"
FX="$HERE/test-fixtures/sink-part2"
eval "$(sed -n '/^# >>> sink_part2/,/^# <<< sink_part2/p' "$SRC")"
for fn in sp2_unwrap sp2_tok sp2_probe_script sp2_facts sp2_verdict sp2_report sp2_pre_script \
          sp2_plant_script sp2_unplant_script sp2_state_script sp2_fill_facts sp2_lever_verdict; do
    type "$fn" >/dev/null 2>&1 || { echo "FAIL: $fn not found between the sink_part2 markers in $SRC"; exit 1; }
done
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

# wrap <in> <out> [exitcode]: the guest's bytes as qm guest exec returns them.
wrap(){
    python3 - "$1" "$2" "${3:-0}" <<'PY'
import json, sys
text = open(sys.argv[1], 'rb').read().decode('latin-1')
body = json.dumps(text, ensure_ascii=False)
out = '{\n   "exitcode" : %s,\n   "exited" : 1,\n   "out-data" : %s\n}\n' % (sys.argv[3], body)
open(sys.argv[2], 'wb').write(out.encode('utf-8'))
PY
}
# through <in> <out>: wrap, then sp2_unwrap, as the rig reads a reply.
through(){ wrap "$1" "$T/raw.$$" && sp2_unwrap "$T/raw.$$" "$2"; }

# ── the fixtures are the capture's ─────────────────────────────────────────
for f in manifest_step_part2.txt sink_fill_part2.txt sink_status_site-off.json \
         sink_status_all-upload.json sink_status_marker-absent.json \
         pipelines_gate.toml sigmond_gate.toml pipelines_part1.toml \
         switch_view_all-upload.txt switch_view_site-off.txt lever_lines_more.txt \
         smd_err_line.txt SOURCE systemd_show_blocks.txt systemd_show_one.txt \
         systemd_list_units.txt journal_cat.txt SYSTEMD_SOURCE; do
    [ -s "$FX/$f" ] || { echo "FAIL: fixture $FX/$f missing; run test-fixtures/sink-part2/capture.sh (and capture-systemd.sh)"; exit 1; }
done
echo "fixtures from $(head -1 "$FX/SOURCE"); systemd shapes from $(head -2 "$FX/SYSTEMD_SOURCE" | tr '\n' ' ')"
# findings <file>: the FAIL and UNCHECKED lines of a verdict.
findings(){ grep -c '^\(FAIL\|UNCHECKED\):' "$1"; }

# ── the channel ────────────────────────────────────────────────────────────
echo "the channel:"
through "$FX/manifest_step_part2.txt" "$T/u.txt"
check "a reply unwraps to the guest's own lines" "$(cat "$FX/manifest_step_part2.txt")" "$(cat "$T/u.txt")"
check "the wrapped reply is ONE out-data line" 1 "$(grep -c '"out-data" : ' "$T/raw.$$")"
: > "$T/empty.raw"
sp2_unwrap "$T/empty.raw" "$T/x.txt"; check "an empty reply is no reply" 1 "$?"
printf 'ssh: connect to host 10.0.0.2 port 22: No route to host\n' > "$T/junk.raw"
sp2_unwrap "$T/junk.raw" "$T/x.txt"; check "a reply with no JSON is no reply" 1 "$?"

# ── the fresh station: the probe on a scratch guest ────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/smd" <<'X'
#!/bin/bash
[ "$*" = "admin uploader manifest" ] || { echo "stub smd: unexpected '$*'" >&2; exit 2; }
cat "$SP2_FX_STEP"
exit "${SP2_FX_STEPRC:-0}"
X
cat > "$T/bin/hsu" <<'X'
#!/bin/bash
[ "$*" = "sink status --json" ] || { echo "stub hs-uploader: unexpected '$*'" >&2; exit 2; }
cat "$SP2_FX_STATUS"
X
chmod +x "$T/bin/smd" "$T/bin/hsu"

# guest <name> <manifest> <sigmond.toml|-> <marker 0|1> <step output> <status json>
# Builds a scratch guest, runs the probe on it, and leaves the facts in
# $T/<name>.facts and the verdict in $T/<name>.verdict.
guest(){
    local n="$1" r="$T/$1.root"
    mkdir -p "$r/etc/hs-uploader/pipelines.d" "$r/var/lib/hs-uploader"
    cp "$2" "$r/etc/hs-uploader/pipelines.toml"
    [ "$3" = - ] || cp "$3" "$r/etc/hs-uploader/pipelines.d/sigmond.toml"
    [ "$4" = 1 ] && printf 'carried over at 2026-10-01T00:00:00Z\n' > "$r/var/lib/hs-uploader/carry-over-v1.done"
    SP2_ROOT="$r" SP2_SMD="$T/bin/smd" SP2_HSU="$T/bin/hsu" SP2_FX_STEP="$5" SP2_FX_STATUS="$6" \
        bash <(sp2_probe_script) > "$T/$n.out" 2>&1
    through "$T/$n.out" "$T/$n.txt"
    sp2_facts "$T/$n.txt" > "$T/$n.facts"
    sp2_verdict "$T/$n.facts" > "$T/$n.verdict"
}
tk(){ sp2_tok "$T/$1.facts" "$2"; }

echo "a fresh part 2 station (Task 19's manifest step, Task 15's site-off status, the gate render):"
guest good "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_site-off.json"
check "the features line is found"          1   "$(tk good F_LINE)"
check "gate is among its words"             1   "$(tk good F_GATE)"
check "its words"                           "gate,pipelines.d,send-log-v3,switch-files" "$(tk good F_WORDS)"
check "the marker"                          1   "$(tk good MARKER)"
check "status parsed"                       1   "$(tk good ST_JSON)"
check "hs-uploader enforces"                1   "$(tk good ST_ENFORCED)"
check "site off"                            off "$(tk good ST_SITE)"
check "three clients named"                 3   "$(tk good ST_NCLIENTS)"
check "each client's own file at upload"    -   "$(tk good ST_NOTUPLOAD)"
check "no discard in the manifest"          0   "$(tk good DISC)"
check "no banner"                           0   "$(tk good BANNER)"
check "heartbeat not in the legacy manifest" 0  "$(tk good HBLEG)"
check "sigmond.toml present"                1   "$(tk good SIGTOML)"
check "heartbeat in sigmond.toml"           1   "$(tk good HBSIG)"
check "heartbeat governed = false"          1   "$(tk good UNGOVERNED)"
check "no smd error line"                   0   "$(tk good SMDERR)"
check "the probe finished"                  1   "$(tk good END)"
check "the verdict finds nothing, and finishes" "VERDICT:done" "$(cat "$T/good.verdict")"

echo "what the verdict must catch:"
guest up "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_all-upload.json"
has "site at upload is not a fresh install" "$T/up.verdict" "the site switch reads 'upload' on a fresh install, not off"
check "and is the only finding" 1 "$(findings "$T/up.verdict")"

guest noenf "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_marker-absent.json"
has "hs-uploader finding no marker" "$T/noenf.verdict" "enforces nothing"
has "a client file below upload"    "$T/noenf.verdict" "not at upload on a fresh install: psk-recorder"

guest nomark "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 0 "$FX/manifest_step_part2.txt" "$FX/sink_status_site-off.json"
has "no marker file" "$T/nomark.verdict" "no carry-over marker at /var/lib/hs-uploader/carry-over-v1.done"

guest part1 "$FX/pipelines_part1.toml" - 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_site-off.json"
check "part 1's render: banner counted"     1 "$(tk part1 BANNER)"
check "part 1's render: heartbeat counted"  1 "$(tk part1 HBLEG)"
has "part 1's banner"              "$T/part1.verdict" "SITE SINK OFF banner"
has "heartbeat in the legacy file" "$T/part1.verdict" "the heartbeat still sits in the legacy manifest"
has "no sigmond.toml"              "$T/part1.verdict" "no pipelines.d/sigmond.toml"

# The discard counter's positive control: the captured gate render with one
# discard line added to a pipelines.d file.
cp "$FX/sigmond_gate.toml" "$T/sig-disc.toml"; printf 'discard = true\n' >> "$T/sig-disc.toml"
guest disc "$FX/pipelines_gate.toml" "$T/sig-disc.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_site-off.json"
check "a discard line is counted" 1 "$(tk disc DISC)"
has "and fails" "$T/disc.verdict" "1 discard line(s) in the manifest"

# The features line: smd prints it behind "uploader: ".  Variants of the
# captured step: without gate, without the prefix, behind a warning sign.
sed 's/features: gate /features: /' "$FX/manifest_step_part2.txt" > "$T/nogate.txt"
guest nogate "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$T/nogate.txt" "$FX/sink_status_site-off.json"
check "no gate word" 0 "$(tk nogate F_GATE)"
has "an hs-uploader without gate fails" "$T/nogate.verdict" "hs-uploader offers no gate (features: pipelines.d,send-log-v3,switch-files)"

sed 's/^uploader: hs-uploader features: /hs-uploader features: /' "$FX/manifest_step_part2.txt" > "$T/bare.txt"
guest bare "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$T/bare.txt" "$FX/sink_status_site-off.json"
check "a line without 'uploader: ' is not the features line" 0 "$(tk bare F_LINE)"
has "and the verdict says no features line" "$T/bare.verdict" "printed no 'uploader: hs-uploader features:' line"

sed 's/^uploader: hs-uploader features: /  \xe2\x9a\xa0 uploader: hs-uploader features: /' "$FX/manifest_step_part2.txt" > "$T/sign.txt"
guest sign "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$T/sign.txt" "$FX/sink_status_site-off.json"
check "behind a double-encoded warning sign, still found" 1 "$(tk sign F_GATE)"
check "and the sign did arrive double-encoded" 1 "$(grep -c $'\xc3\xa2\xc2\x9a\xc2\xa0 uploader: hs-uploader features' "$T/sign.txt")"

# A reply cut short: no END:1.
head -3 "$T/good.out" > "$T/cut.out"; through "$T/cut.out" "$T/cut.txt"
sp2_facts "$T/cut.txt" > "$T/cut.facts"; sp2_verdict "$T/cut.facts" > "$T/cut.verdict"
has "a cut reply is not a verdict" "$T/cut.verdict" "gave no answer (guest exec failed; not a verdict)"
check "and says nothing else" 1 "$(findings "$T/cut.verdict")"
check "but still finishes" 1 "$(grep -cx 'VERDICT:done' "$T/cut.verdict")"

# The manifest step's exit code and its error lines (M-1).
SP2_FX_STEPRC=1 guest steprc "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_site-off.json"
check "the step's exit code is read" 1 "$(tk steprc STEPRC)"
has "a failed manifest step fails" "$T/steprc.verdict" "FAIL: smd admin uploader manifest exited 1"
cat "$FX/manifest_step_part2.txt" "$FX/smd_err_line.txt" > "$T/step-err.txt"
guest smderr "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$T/step-err.txt" "$FX/sink_status_site-off.json"
check "an smd error line is counted" 1 "$(tk smderr SMDERR)"
has "and fails" "$T/smderr.verdict" "printed 1 'smd: uploader:' error line(s)"

# ── the phrases the rig greps from smd sink status ─────────────────────────
echo "smd sink status, part 2's switch view (Task 21), through the channel:"
through "$FX/switch_view_all-upload.txt" "$T/sv-up.txt"
through "$FX/switch_view_site-off.txt" "$T/sv-off.txt"
has   "after smd sink upload: the upload phrase" "$T/sv-up.txt"  "$SP2_UPLOAD_PHRASE"
hasnt "site off: no upload phrase"               "$T/sv-off.txt" "$SP2_UPLOAD_PHRASE"
has   "site off: the off phrase"                 "$T/sv-off.txt" "$SP2_OFF_PHRASE"
check "the rig greps the upload phrase" 1 "$(grep -c 'grep -qF "$SP2_UPLOAD_PHRASE"' "$SRC")"
check "the rig greps the off phrase"    1 "$(grep -c 'grep -qF "$SP2_OFF_PHRASE"' "$SRC")"

# ── smd sink fill ──────────────────────────────────────────────────────────
# The rig's own fill command (SP2_FILL), with smd stood in by a script that
# prints the captured output and exits with the code given.
cat > "$T/bin/smdfill" <<'X'
#!/bin/bash
[ "$*" = "sink fill --reason rig" ] || { echo "stub smd: unexpected '$*'" >&2; exit 2; }
cat "$SP2_FX_FILL"
exit "${SP2_FX_RC:-0}"
X
chmod +x "$T/bin/smdfill"
fillout(){ # <out> <rc> <fixture>...
    local o="$1" rc="$2"; shift 2
    cat "$@" > "$T/fill.fx"
    SP2_SMD="$T/bin/smdfill" SP2_FX_FILL="$T/fill.fx" SP2_FX_RC="$rc" bash -c "$SP2_FILL" > "$o" 2>&1
}
echo "smd sink fill (Task 20's capture):"
fillout "$T/fill.out" 0 "$FX/sink_fill_part2.txt"
through "$T/fill.out" "$T/fill.txt"; sp2_fill_facts "$T/fill.txt" > "$T/fill.facts"
fk(){ sp2_tok "$T/fill.facts" "$1"; }
check "psk-recorder lever written"   1 "$(fk CHG_PSK)"
check "wspr-recorder lever written"  1 "$(fk CHG_WSPR)"
check "no meteor-scatter lever"      0 "$(fk CHG_MS)"
check "no mag lever"                 0 "$(fk CHG_MAG)"
check "two units restarted"          2 "$(fk RESTARTED)"
check "psk-recorder restarted once"  1 "$(nlines "$T/fill.facts" '^RESTART|psk-recorder@W1AW.service|1$')"
check "wspr-recorder restarted once" 1 "$(nlines "$T/fill.facts" '^RESTART|wspr-recorder@W1AW.service|1$')"
check "site set to fill"             1 "$(fk SITE_FILL)"
check "no lever failed"              0 "$(fk LV_FAILED)"
check "nothing still armed"          0 "$(fk LV_ARMED)"
check "hs-uploader left alone (manifest already current)" 0 "$(fk HSU_RESTART)"
check "fill exit code"               0 "$(fk FILLRC)"

fillout "$T/fill2.out" 0 "$FX/sink_fill_part2.txt" "$FX/lever_lines_more.txt"
through "$T/fill2.out" "$T/fill2.txt"; sp2_fill_facts "$T/fill2.txt" > "$T/fill2.facts"
check "meteor-scatter lever written"       1 "$(sp2_tok "$T/fill2.facts" CHG_MS)"
check "mag lever written"                  1 "$(sp2_tok "$T/fill2.facts" CHG_MAG)"
check "wspr-uploader stopped and disabled" 1 "$(sp2_tok "$T/fill2.facts" WU_DISABLED)"
check "a stale-writer restart counts"      1 "$(nlines "$T/fill2.facts" '^RESTART|wspr-recorder@N0CALL\\x3dT1.service|1$')"

grep -F 'lever: restarted psk-recorder@W1AW.service' "$FX/sink_fill_part2.txt" > "$T/again.txt"
fillout "$T/fill3.out" 0 "$FX/sink_fill_part2.txt" "$T/again.txt"
through "$T/fill3.out" "$T/fill3.txt"; sp2_fill_facts "$T/fill3.txt" > "$T/fill3.facts"
check "a second restart line counts twice" 1 "$(nlines "$T/fill3.facts" '^RESTART|psk-recorder@W1AW.service|2$')"

# ── sp2_report: a verdict must finish ──────────────────────────────────────
# The rig's say and sink_unchecked, stood in.
say(){ echo "SAY: $*"; }
sink_unchecked(){ echo "KEPT: $*"; }
report(){ # <name> <verdict>: sp2_report's output in $T/<name>.rep, its exit code echoed
    ( sp2_report "$2" /dev/null ) > "$T/$1.rep" 2>&1; echo "$?"
}
echo "sp2_report:"
printf 'UNCHECKED: a thing\nVERDICT:done\n' > "$T/v-ok.txt"
check "a finished verdict with nothing failed passes" 0 "$(report vok "$T/v-ok.txt")"
has "an UNCHECKED line is said" "$T/vok.rep" "SAY: ⚠ NOT EVALUATED: a thing"
has "and kept for the closing line" "$T/vok.rep" "KEPT: a thing"
printf 'FAIL: a thing\nVERDICT:done\n' > "$T/v-fail.txt"
check "a FAIL line is FATAL" 1 "$(report vfail "$T/v-fail.txt")"
printf 'UNCHECKED: a thing\n' > "$T/v-crash.txt"
check "a verdict without VERDICT:done is FATAL" 1 "$(report vcrash "$T/v-crash.txt")"
has "as no verdict" "$T/vcrash.rep" "the verdict did not finish (it crashed or was cut short; not a verdict)"
check "a missing verdict file is FATAL" 1 "$(report vnone "$T/no-such-file")"

# ── the lever verdict ──────────────────────────────────────────────────────
# The planted psk-recorder instance is the capture's W1AW (its env file at
# the capture's @ROOT@ path).  The plant, before and after replies are the
# rig's own scripts' format.
P=psk-recorder@W1AW.service
W=wspr-recorder@W1AW.service
plant(){ cat <<X
PRE|psk-recorder|${PSKPRE:-1}|1|${PSKGOV:-1}
ROWS|psk-recorder|0
PRE|meteor-scatter|0|0|nofixed
ROWS|meteor-scatter|${MSROWS:-0}
PRE|wspr-recorder|${WSPRPRE:-1}|1|1
ROWS|wspr-recorder|0
PRE|mag-recorder|${MAGPRE:-1}|1|${MAGGOV:-1}
ROWS|mag-recorder|0
PREDONE:1
PSK:1
PSK_TOPO:1
PSK_SWITCH:${PSKSW:-pre}
PSK_ENVSET:0
PSK_START:0
PSK_INVENTED:0
PLANTED|psk-recorder|$P|@ROOT@/etc/psk-recorder/env/W1AW.env
MS:0
${1:-WU:0}
${2:-MAG:0}
END:1
X
}
before(){ cat <<X
UNIT|1|$P|active|1000
UNIT|1|$W|active|1100
UNIT|1|hs-uploader.service|active|500
RADIOD|1|radiod@rx888.service|active|100
RADIODN|1|1
UNIT|2|$P|active|1000
UNIT|2|$W|active|1100
UNIT|2|hs-uploader.service|active|500
RADIOD|2|radiod@rx888.service|active|100
RADIODN|2|1
LEVER|psk-recorder|direct
WUSTATE|enabled|inactive
MAGEN|bool:true
T0:1790000000
T0MONO:2000
END:1
X
}
after(){ # [psk mono] [psk starts] [radiod mono] [hs-uploader mono] [psk lever] [wu] [mag] [hs-uploader starts]
    cat <<X
UNIT|A|$P|active|${1:-3000}
UNIT|A|$W|active|3100
UNIT|A|hs-uploader.service|active|${4:-500}
RADIOD|A|radiod@rx888.service|active|${3:-100}
RADIODN|A|1
LEVER|psk-recorder|${5:-server-raw}
WUSTATE|${6:-disabled|inactive}
MAGEN|${7:-bool:false}
STARTS|$P|${2:-1}
STARTS|$W|1
STARTS|hs-uploader.service|${8:-0}
T0:1790000000
END:1
X
}
lv(){ # <name> <plant> <before> <fill facts> <after>
    sp2_lever_verdict "$2" "$3" "$4" "$5" > "$T/$1.lv" 2>"$T/$1.lverr"
}
done_(){ grep -cx 'VERDICT:done' "$1"; }
plant > "$T/p.txt"; before > "$T/b.txt"; after > "$T/a.txt"
echo "the lever verdict on the capture:"
lv ok "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
check "no FAIL"                       0 "$(nlines "$T/ok.lv" '^FAIL')"
check "finished"                      1 "$(done_ "$T/ok.lv")"
check "three levers this nest cannot show, said" 3 "$(nlines "$T/ok.lv" '^UNCHECKED: the \(meteor-scatter\|wspr-uploader\|mag-recorder\) lever')"
check "nothing else unchecked"        3 "$(nlines "$T/ok.lv" '^UNCHECKED')"

echo "what it must catch:"
after 1000 > "$T/a1.txt"; lv norestart "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a1.txt"
has "a unit that never started again" "$T/norestart.lv" "FAIL: $P did not start again after the fill began"
after 3000 2 > "$T/a2.txt"; lv twice "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a2.txt"
has "a unit started twice" "$T/twice.lv" "FAIL: $P started 2 times since the fill began"
lv twicesaid "$T/p.txt" "$T/b.txt" "$T/fill3.facts" "$T/a.txt"
has "smd naming a restart twice" "$T/twicesaid.lv" "FAIL: smd sink fill says it restarted $P 2 times"
after 3000 1 4000 > "$T/a3.txt"; lv radiod "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a3.txt"
has "radiod moved" "$T/radiod.lv" "FAIL: radiod moved during the fill: radiod@rx888.service"
after 3000 1 100 2500 > "$T/a4.txt"; lv hsu "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a4.txt"
has "an unnamed unit that moved" "$T/hsu.lv" "FAIL: hs-uploader.service moved during the fill"
sed "s/^UNIT|A|$W|active|3100/UNIT|A|$W|active|1100/" "$T/a.txt" > "$T/aw.txt"
lv wsprstill "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/aw.txt"
has "a named recorder instance that did not restart" "$T/wsprstill.lv" "FAIL: $W did not start again after the fill began"
after 3000 1 100 500 direct > "$T/a5.txt"; lv lever "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a5.txt"
has "a lever not on disk" "$T/lever.lv" "FAIL: psk-recorder's env file reads 'direct' after the fill"
awk -v p="$P" '/^PLANTED\|/ { print "PLANTED|psk-recorder|" p "|/etc/psk-recorder/env/OTHER.env"; next } { print }' "$T/p.txt" > "$T/pother.txt"
lv otherfile "$T/pother.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a lever written to another file" "$T/otherfile.lv" "FAIL: smd sink fill did not write the psk-recorder lever at /etc/psk-recorder/env/OTHER.env"
fillout "$T/fillrc.out" 1 "$FX/sink_fill_part2.txt"; through "$T/fillrc.out" "$T/fillrc.txt"
sp2_fill_facts "$T/fillrc.txt" > "$T/fillrc.facts"; lv rc "$T/p.txt" "$T/b.txt" "$T/fillrc.facts" "$T/a.txt"
has "a failed fill" "$T/rc.lv" "FAIL: smd sink fill --reason rig exited 1"
grep -v '^END:1$' "$T/a.txt" > "$T/acut.txt"; lv cut "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/acut.txt"
has "a cut reply is not a verdict" "$T/cut.lv" "gave no answer (guest exec failed; not a verdict)"
check "and says nothing else" 1 "$(findings "$T/cut.lv")"
check "but finishes" 1 "$(done_ "$T/cut.lv")"
# radiod: RADIODN counts the running units apart from the records.
sed 's/^RADIODN|\(.\)|1$/RADIODN|\1|0/; /^RADIOD|/d' "$T/b.txt" > "$T/bnr.txt"
sed 's/^RADIODN|\(.\)|1$/RADIODN|\1|0/; /^RADIOD|/d' "$T/a.txt" > "$T/anr.txt"
lv noradiod "$T/p.txt" "$T/bnr.txt" "$T/fill.facts" "$T/anr.txt"
has "no radiod in the nest is said, not passed" "$T/noradiod.lv" "UNCHECKED: radiod's start time across the fill"
check "and fails nothing" 0 "$(nlines "$T/noradiod.lv" '^FAIL')"
hasnt "with radiod running, nothing unchecked about it" "$T/ok.lv" "radiod's start time"
grep -v '^RADIOD|' "$T/b.txt" > "$T/blost.txt"; grep -v '^RADIOD|' "$T/a.txt" > "$T/alost.txt"
lv radiodlost "$T/p.txt" "$T/blost.txt" "$T/fill.facts" "$T/alost.txt"
has "radiod running, its records lost: FAIL" "$T/radiodlost.lv" "FAIL: 1/1 radiod unit(s) run (before/after), but the start times of 0/0 were read"
hasnt "never UNCHECKED" "$T/radiodlost.lv" "UNCHECKED: radiod"
grep -v '^RADIODN|' "$T/b.txt" > "$T/bnc.txt"
lv radiodnocount "$T/p.txt" "$T/bnc.txt" "$T/fill.facts" "$T/a.txt"
has "no radiod count: FAIL" "$T/radiodnocount.lv" "FAIL: the probes did not count the running radiod units"
# The pre-fill reads disagree: the restart count cannot be judged.
sed "s/^UNIT|2|$P|active|1000/UNIT|2|$P|active|1500/" "$T/b.txt" > "$T/bun.txt"
lv unsteady "$T/p.txt" "$T/bun.txt" "$T/fill.facts" "$T/a.txt"
has "an unsteady unit is said, not judged" "$T/unsteady.lv" "UNCHECKED: the restart count of $P"

echo "hs-uploader named by the step (M-3):"
grep -F 'uploader: wrote' "$FX/manifest_step_part2.txt" | grep -F pipelines.toml > "$T/hsuline.txt"
fillout "$T/fillh.out" 0 "$FX/sink_fill_part2.txt" "$T/hsuline.txt"
through "$T/fillh.out" "$T/fillh.txt"; sp2_fill_facts "$T/fillh.txt" > "$T/fillh.facts"
check "a manifest write names the daemon's restart" 1 "$(sp2_tok "$T/fillh.facts" HSU_RESTART)"
after 3000 1 100 2500 server-raw 'disabled|inactive' bool:false 1 > "$T/ah1.txt"
lv hsuok "$T/p.txt" "$T/b.txt" "$T/fillh.facts" "$T/ah1.txt"
check "restarted once: no FAIL" 0 "$(nlines "$T/hsuok.lv" '^FAIL')"
lv hsustill "$T/p.txt" "$T/b.txt" "$T/fillh.facts" "$T/a.txt"
has "named but never restarted" "$T/hsustill.lv" "FAIL: hs-uploader.service did not start again after the fill began"
after 3000 1 100 2500 server-raw 'disabled|inactive' bool:false 2 > "$T/ah2.txt"
lv hsutwice "$T/p.txt" "$T/b.txt" "$T/fillh.facts" "$T/ah2.txt"
has "named, started twice" "$T/hsutwice.lv" "FAIL: hs-uploader.service started 2 times since the fill began"

echo "every recorder instance (M-4):"
sed 's/W1AW/K1ABC/g' "$FX/sink_fill_part2.txt" | grep -F 'lever: changed' | grep -F psk-recorder > "$T/psk2.txt"
fillout "$T/fillp2.out" 0 "$FX/sink_fill_part2.txt" "$T/psk2.txt"
through "$T/fillp2.out" "$T/fillp2.txt"; sp2_fill_facts "$T/fillp2.txt" > "$T/fillp2.facts"
check "two psk lever files" 2 "$(sp2_tok "$T/fillp2.facts" CHG_PSK)"
lv psk2 "$T/p.txt" "$T/b.txt" "$T/fillp2.facts" "$T/a.txt"
check "two psk instances: no FAIL" 0 "$(nlines "$T/psk2.lv" '^FAIL')"
{ cat "$T/b.txt"; printf 'UNIT|1|wspr-recorder@K1ABC.service|active|1200\nUNIT|2|wspr-recorder@K1ABC.service|active|1200\n'; } > "$T/bk.txt"
{ cat "$T/a.txt"; printf 'UNIT|A|wspr-recorder@K1ABC.service|active|3300\nSTARTS|wspr-recorder@K1ABC.service|1\n'; } > "$T/ak.txt"
lv unnamed "$T/p.txt" "$T/bk.txt" "$T/fill.facts" "$T/ak.txt"
has "an instance smd never named moved" "$T/unnamed.lv" "FAIL: wspr-recorder@K1ABC.service moved during the fill"
{ cat "$T/b.txt"; printf 'UNIT|1|wspr-recorder@K1ABC.service|activating|1200\nUNIT|2|wspr-recorder@K1ABC.service|active|1250\n'; } > "$T/bloop.txt"
lv crashloop "$T/p.txt" "$T/bloop.txt" "$T/fill.facts" "$T/ak.txt"
has "a crash-looping unnamed instance that moves is said" "$T/crashloop.lv" "UNCHECKED: wspr-recorder@K1ABC.service did not hold still before the fill"
check "not failed" 0 "$(nlines "$T/crashloop.lv" '^FAIL')"

echo "the carry-over before the plant (I-2):"
PSKPRE=0 PSKSW=missing plant > "$T/pmiss.txt"
lv carrymiss "$T/pmiss.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "an enabled client without a switch file" "$T/carrymiss.lv" "FAIL: the carry-over wrote no switch file for an enabled client: psk-recorder"
WSPRPRE=0 plant > "$T/pmissw.txt"
lv carrymissw "$T/pmissw.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "whatever the plant does after" "$T/carrymissw.lv" "FAIL: the carry-over wrote no switch file for an enabled client: wspr-recorder"
PSKPRE=0 PSKGOV=0 PSKSW=missing plant > "$T/pngov.txt"
lv notgoverned "$T/pngov.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
hasnt "an enabled client declaring no pipeline is owed no file" "$T/notgoverned.lv" "the carry-over wrote no switch file"
has "and its lever is said unreachable" "$T/notgoverned.lv" "UNCHECKED: the psk-recorder lever (psk-recorder has no switch file"
MAGPRE=0 MAGGOV=nofixed plant > "$T/pninst.txt"
lv notinstalled "$T/pninst.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
check "enabled but not installed: no FAIL" 0 "$(nlines "$T/notinstalled.lv" '^FAIL')"
has "said unchecked" "$T/notinstalled.lv" "UNCHECKED: whether the carry-over owed mag-recorder a switch file (enabled, but no deploy.toml at a fixed path)"
MSROWS=3 plant > "$T/prows.txt"
lv disabledrows "$T/prows.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a disabled client with sink.db rows is said" "$T/disabledrows.lv" "UNCHECKED: whether the carry-over owed meteor-scatter a switch file (disabled, but 3 sink.db row(s)"
check "and fails nothing" 0 "$(nlines "$T/disabledrows.lv" '^FAIL')"
PSKSW=failed plant > "$T/pfail.txt"
lv swfail "$T/pfail.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a switch file the rig could not write" "$T/swfail.lv" "FAIL: the rig could not write a switch file for psk-recorder"

echo "a crashed verdict (I-1):"
{ cat "$T/fill.facts"; echo 'RESTART|psk-recorder@W1AW.service|x'; } > "$T/fillbad.facts"
lv crash "$T/p.txt" "$T/b.txt" "$T/fillbad.facts" "$T/a.txt"
check "a malformed line crashes it: no VERDICT:done" 0 "$(done_ "$T/crash.lv")"
has "its exit code is said" "$T/crash.lv" "FAIL: the lever verdict exited 1 (not a verdict)"
check "and sp2_report refuses it" 1 "$(report crash "$T/crash.lv")"
has "as no verdict" "$T/crash.rep" "not a verdict"
lv okrep "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
check "while the good verdict reports clean" 0 "$(report okrep "$T/okrep.lv")"

echo "wspr-uploader and the mag fallback planted:"
grep -E 'wspr-uploader|mag-recorder' "$FX/lever_lines_more.txt" > "$T/wm-lines.txt"
fillout "$T/fillwm.out" 0 "$FX/sink_fill_part2.txt" "$T/wm-lines.txt"
through "$T/fillwm.out" "$T/fillwm.txt"; sp2_fill_facts "$T/fillwm.txt" > "$T/fillwm.facts"
plant "$(printf 'WU:1\nWU_ENABLE:0\nWU_SWITCH:pre')" "$(printf 'MAG:1\nMAG_SET:0\nMAG_SWITCH:pre')" > "$T/pwm.txt"
lv wm "$T/pwm.txt" "$T/b.txt" "$T/fillwm.facts" "$T/a.txt"
check "with their lines, no FAIL" 0 "$(nlines "$T/wm.lv" '^FAIL')"
hasnt "no wspr-uploader finding" "$T/wm.lv" "wspr-uploader"
hasnt "no mag finding"           "$T/wm.lv" "mag-recorder"
lv wmmiss "$T/pwm.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "the fill not disabling wspr-uploader" "$T/wmmiss.lv" "FAIL: smd sink fill did not stop and disable wspr-uploader.service"
has "the fill not writing the mag lever"   "$T/wmmiss.lv" "FAIL: smd sink fill did not write the mag-recorder lever"
after 3000 1 100 500 server-raw 'enabled|inactive' "'false'" > "$T/a6.txt"
lv wmdisk "$T/pwm.txt" "$T/b.txt" "$T/fillwm.facts" "$T/a6.txt"
has "wspr-uploader still enabled" "$T/wmdisk.lv" "FAIL: wspr-uploader.service reads"
has "mag's enabled a string"      "$T/wmdisk.lv" "not the boolean false"

# ── sp2_state_script, hermetic (M-2) ───────────────────────────────────────
# systemctl and journalctl stood in by scripts that serve a table of units in
# the shapes captured from a real systemd (capture-systemd.sh).  First the
# stand-ins must print exactly what systemd printed for the captured units.
cat > "$T/bin/systemctl" <<'X'
#!/usr/bin/env python3
# A stand-in systemctl: show, list-units; any other verb is logged.
import fnmatch, os, sys
args = sys.argv[1:]
with open(os.environ['STUB_LOG'], 'a') as fh:
    fh.write(' '.join(args) + '\n')
if args[:1] and args[0] == os.environ.get('STUB_FAIL'):
    sys.exit(1)            # the verb the test makes fail
table = {}
for l in open(os.environ['STUB_TABLE']):
    l = l.rstrip('\n')
    if l:
        u, st, mo, sub, ufs, desc = (l.split('|') + [''] * 6)[:6]
        table[u] = {'ActiveState': st, 'ActiveEnterTimestampMonotonic': mo,
                    'sub': sub, 'UnitFileState': ufs, 'desc': desc}
def props(u):
    p = table.get(u) or {'ActiveState': 'inactive', 'ActiveEnterTimestampMonotonic': '0',
                         'sub': 'dead', 'UnitFileState': '', 'desc': ''}
    return dict(p, Id=u)
pats = [a for a in args[1:] if not a.startswith('-')]
if args[:1] == ['show']:
    ps = [args[i + 1] for i, a in enumerate(args) if a == '-p']
    names = [a for i, a in enumerate(args[1:], 1) if not a.startswith('-') and args[i - 1] != '-p']
    blocks = []
    for n in names:
        for u in (sorted(u for u in table if fnmatch.fnmatchcase(u, n)) if '*' in n else [n]):
            p = props(u)
            blocks.append('\n'.join('%s=%s' % (k, p[k]) for k in ps))
    if blocks:
        print('\n\n'.join(blocks))
elif args[:1] == ['list-units']:
    for u in sorted(table):
        p = table[u]
        if '--state=active' in args and p['ActiveState'] != 'active':
            continue
        if any(fnmatch.fnmatchcase(u, pt) for pt in pats):
            print('%s loaded %s %s %s' % (u, p['ActiveState'], p['sub'], p['desc']))
X
cat > "$T/bin/journalctl" <<'X'
#!/bin/bash
# A stand-in journalctl -u UNIT ... -o cat: the file the test wrote for UNIT.
u=""; while [ $# -gt 0 ]; do [ "$1" = -u ] && { u="$2"; shift; }; shift; done
f="$STUB_JOURNAL/$(printf '%s' "$u" | md5sum | cut -c1-16)"
[ -f "$f" ] && cat "$f"
exit 0
X
chmod +x "$T/bin/systemctl" "$T/bin/journalctl"
export STUB_LOG="$T/stub.log" STUB_TABLE="$T/units.tbl" STUB_JOURNAL="$T/journal"
mkdir -p "$STUB_JOURNAL"
RUN_U=$(sed -n 's/^running //p' "$FX/SYSTEMD_SOURCE"); JRN_U=$(sed -n 's/^journal //p' "$FX/SYSTEMD_SOURCE")
read -r RUN_ST RUN_MO < <(awk -F= '$1 == "ActiveState" { s = $2 } $1 == "ActiveEnterTimestampMonotonic" { m = $2 } END { print s, m }' "$FX/systemd_show_one.txt")
RUN_DESC=$(awk '{ $1 = $2 = $3 = $4 = ""; sub(/^ +/, ""); print; exit }' "$FX/systemd_list_units.txt")
RUN_SUB=$(awk '{ print $4; exit }' "$FX/systemd_list_units.txt")
echo "$RUN_U|$RUN_ST|$RUN_MO|$RUN_SUB||$RUN_DESC" > "$STUB_TABLE"
echo "the stand-ins against the captured systemd ($RUN_U):"
check "show, three kinds of name, as systemd printed it" "$(cat "$FX/systemd_show_blocks.txt")" \
    "$("$T/bin/systemctl" show -p Id -p ActiveState -p ActiveEnterTimestampMonotonic 'sp2nosuchunit@*' sp2nosuchunit.service "$RUN_U")"
check "show, one unit"   "$(cat "$FX/systemd_show_one.txt")" "$("$T/bin/systemctl" show -p ActiveState -p ActiveEnterTimestampMonotonic "$RUN_U")"
check "list-units"       "$(cat "$FX/systemd_list_units.txt")" \
    "$("$T/bin/systemctl" list-units --type=service --state=active --plain --no-legend "$RUN_U" 'sp2nosuchunit@*')"
# journal_for UNIT N: N start episodes of the captured journal, renamed.
EPISODE=$(awk '/^Started / { n++ } n == 1' "$FX/journal_cat.txt")
check "the captured journal holds a start episode" 1 "$(printf '%s\n' "$EPISODE" | grep -c '^Started ')"
journal_for(){
    local f="$STUB_JOURNAL/$(printf '%s' "$1" | md5sum | cut -c1-16)" i
    : > "$f"
    for i in $(seq 1 "$2"); do printf '%s\n' "$EPISODE" | sed "s/$JRN_U/$1/g" >> "$f"; done
}

echo "sp2_state_script on a stood-in guest:"
SD="$T/sd"; mkdir -p "$SD/run" "$SD/root/etc/psk-recorder/env" "$SD/root/etc/mag-recorder"
ENVF="$SD/root/etc/psk-recorder/env/W1AW.env"
printf 'PSK_DELIVERY_PIPELINES=direct\n' > "$ENVF"
printf '[uploader]\nenabled = true\n' > "$SD/root/etc/mag-recorder/mag-recorder-config.toml"
printf 'PLANTED|psk-recorder|%s|%s\n' "$P" "$ENVF" > "$SD/run/planted"
cat > "$STUB_TABLE" <<X
$P|active|1000|running||psk
$W|active|1100|running||wspr
wspr-recorder@K1ABC.service|active|1200|running||wspr
hs-uploader.service|active|500|running||hsu
radiod@rx888.service|active|100|running||radiod
wspr-uploader.service|inactive|0|dead|enabled|wu
X
state(){ # <phase> <out>
    SP2_RUN="$SD/run" SP2_ROOT="$SD/root" SP2_SYSTEMCTL="$T/bin/systemctl" SP2_JOURNALCTL="$T/bin/journalctl" SP2_SLEEP=0 \
        bash <(sp2_state_script "$1") > "$T/$1.out" 2>&1
    through "$T/$1.out" "$2"
}
state before "$T/sb.txt"
check "every recorder instance watched" 4 "$(grep -c '^UNIT|2|' "$T/sb.txt")"
has "the unwatched-by-plant instance too" "$T/sb.txt" "UNIT|2|wspr-recorder@K1ABC.service|active|1200"
has "radiod read through its awk" "$T/sb.txt" "RADIOD|2|radiod@rx888.service|active|100"
has "radiod counted apart"        "$T/sb.txt" "RADIODN|2|1"
has "the planted lever file read" "$T/sb.txt" "LEVER|psk-recorder|direct"
has "wspr-uploader read"          "$T/sb.txt" "WUSTATE|enabled|inactive"
has "mag read"                    "$T/sb.txt" "MAGEN|bool:true"
T0M=$(sp2_tok "$T/sb.txt" T0MONO)
# The fill: psk and wspr@W1AW restart once, past T0; the levers land.
cat > "$STUB_TABLE" <<X
$P|active|$((T0M + 1000))|running||psk
$W|active|$((T0M + 2000))|running||wspr
wspr-recorder@K1ABC.service|active|1200|running||wspr
hs-uploader.service|active|500|running||hsu
radiod@rx888.service|active|100|running||radiod
wspr-uploader.service|inactive|0|dead|disabled|wu
X
printf 'PSK_DELIVERY_PIPELINES=server-raw\n' > "$ENVF"
printf '[uploader]\nenabled = false\n' > "$SD/root/etc/mag-recorder/mag-recorder-config.toml"
journal_for "$P" 1; journal_for "$W" 1
state after "$T/sa.txt"
has "a start counted from the journal" "$T/sa.txt" "STARTS|$P|1"
has "no start, none counted"           "$T/sa.txt" "STARTS|hs-uploader.service|0"
lv hermetic "$T/pwm.txt" "$T/sb.txt" "$T/fillwm.facts" "$T/sa.txt"
check "the whole chain: no FAIL" 0 "$(nlines "$T/hermetic.lv" '^FAIL')"
check "only meteor-scatter unchecked" 1 "$(findings "$T/hermetic.lv")"
check "finished" 1 "$(done_ "$T/hermetic.lv")"
journal_for "$P" 2
state after "$T/sa2.txt"
lv hermetic2 "$T/pwm.txt" "$T/sb.txt" "$T/fillwm.facts" "$T/sa2.txt"
has "two journal starts fail" "$T/hermetic2.lv" "FAIL: $P started 2 times since the fill began"

# ── inst_for: an escaped env file name is not escaped twice (M-5) ──────────
echo "inst_for:"
eval "$(sp2_plant_script | sed -n '/^inst_for(){/,/^}/p')"
IR="$T/ir"; mkdir -p "$IR/etc/psk-recorder/env"
check "no env file: the rig's own instance" "N0CALL=T1" "$(SP2_ROOT="$IR" inst_for psk-recorder)"
: > "$IR/etc/psk-recorder/env/AC0G\\x3dB4.env"
check "an escaped name, unescaped" "AC0G=B4" "$(SP2_ROOT="$IR" inst_for psk-recorder)"
check "and its unit escaped once" 'psk-recorder@AC0G\x3dB4.service' "psk-recorder@$(systemd-escape -- "$(SP2_ROOT="$IR" inst_for psk-recorder)").service"
: > "$IR/etc/psk-recorder/env/AC0G=B4.env"
check "the storage name preferred" "AC0G=B4" "$(SP2_ROOT="$IR" inst_for psk-recorder)"

# ── sp2_pre_script, hermetic (N-2) ─────────────────────────────────────────
echo "sp2_pre_script (the carry-over's own rule):"
PR="$T/pre"; mkdir -p "$PR/etc/sigmond" "$PR/etc/hs-uploader/sinks" "$PR/var/lib/sigmond" \
    "$PR/opt/git/sigmond/psk-recorder" "$PR/opt/git/sigmond/wspr-recorder" "$PR/srv/clients/mag-recorder"
cat > "$PR/etc/sigmond/topology.toml" <<'X'
[sigmond]
client_dir = "/srv/clients"

[component.psk-recorder]
enabled = true

[component.wspr-recorder]
enabled = true

[component.mag-recorder]
enabled = true

[component.meteor-scatter]
enabled = false
X
printf '[[hs_uploader.pipeline]]\nname = "psk-pskreporter"\n' > "$PR/opt/git/sigmond/psk-recorder/deploy.toml"
printf '[package]\nname = "wspr-recorder"\n' > "$PR/opt/git/sigmond/wspr-recorder/deploy.toml"
printf '[[hs_uploader.pipeline]]\nname = "mag-psws"\n' > "$PR/srv/clients/mag-recorder/deploy.toml"
: > "$PR/etc/hs-uploader/sinks/wspr-recorder.toml"
python3 - "$PR/var/lib/sigmond/sink.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE pending_uploads (id INTEGER PRIMARY KEY, producer TEXT)")
c.executemany("INSERT INTO pending_uploads (producer) VALUES (?)", [("meteor-scatter",), ("meteor-scatter",), ("",)])
c.commit()
PY
SP2_ROOT="$PR" bash <(sp2_pre_script) > "$T/pre.out" 2>&1
check "enabled, governed at /opt/git/sigmond, no file" 1 "$(grep -cx 'PRE|psk-recorder|0|1|1' "$T/pre.out")"
check "enabled, deploy.toml declares no pipeline"        1 "$(grep -cx 'PRE|wspr-recorder|1|1|0' "$T/pre.out")"
check "topology's client_dir ignored, as sigmond does"   1 "$(grep -cx 'PRE|mag-recorder|0|1|nofixed' "$T/pre.out")"
check "the probe finished"                               1 "$(grep -cx 'PREDONE:1' "$T/pre.out")"
check "disabled, not installed"                          1 "$(grep -cx 'PRE|meteor-scatter|0|0|nofixed' "$T/pre.out")"
check "its sink.db rows counted"                         1 "$(grep -cx 'ROWS|meteor-scatter|2' "$T/pre.out")"
mkdir -p "$PR/opt/git/sigmond/mag-recorder"; cp "$PR/srv/clients/mag-recorder/deploy.toml" "$PR/opt/git/sigmond/mag-recorder/"
SP2_ROOT="$PR" bash <(sp2_pre_script) > "$T/pre2.out" 2>&1
check "the same deploy.toml at /opt/git/sigmond: governed" 1 "$(grep -cx 'PRE|mag-recorder|0|1|1' "$T/pre2.out")"
{ cat "$T/pre.out"; grep -v '^PRE|\|^ROWS|' "$T/p.txt"; } > "$T/ppre.txt"
lv prechain "$T/ppre.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "the chain fails psk-recorder"          "$T/prechain.lv" "FAIL: the carry-over wrote no switch file for an enabled client: psk-recorder"
has "mag-recorder, not at a fixed path, said" "$T/prechain.lv" "UNCHECKED: whether the carry-over owed mag-recorder a switch file (enabled, but no deploy.toml at a fixed path)"
# M-A: a pre probe that crashed, or printed only part, is no verdict.
printf 'Traceback (most recent call last):\n  File "<stdin>", line 3\nNameError: boom\n' > "$T/precrash.out"
{ cat "$T/precrash.out"; grep -v '^PRE|\|^ROWS|\|^PREDONE' "$T/p.txt"; } > "$T/pcrash.txt"
lv precrash "$T/pcrash.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a crashed pre probe fails" "$T/precrash.lv" "FAIL: the pre probe gave no answer (not a verdict)"
check "and says nothing else" 1 "$(findings "$T/precrash.lv")"
check "but finishes" 1 "$(done_ "$T/precrash.lv")"
grep -v '^PRE|mag-recorder' "$T/p.txt" > "$T/ppart.txt"
lv prepart "$T/ppart.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a pre probe missing a client fails" "$T/prepart.lv" "FAIL: the pre probe gave no answer (not a verdict)"
grep -v '^PREDONE' "$T/p.txt" > "$T/pnodone.txt"
lv prenodone "$T/pnodone.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "a pre probe without PREDONE fails" "$T/prenodone.lv" "FAIL: the pre probe gave no answer (not a verdict)"
# The real script crashing: python3 shadowed by one that dies.
mkdir -p "$T/deadpy"; printf '#!/bin/sh\nexit 1\n' > "$T/deadpy/python3"; chmod +x "$T/deadpy/python3"
PATH="$T/deadpy:$PATH" SP2_ROOT="$PR" bash <(sp2_pre_script) > "$T/predead.out" 2>&1
{ cat "$T/predead.out"; grep -v '^PRE|\|^ROWS|\|^PREDONE' "$T/p.txt"; } > "$T/pdead.txt"
lv predead "$T/pdead.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "the pre script dying fails" "$T/predead.lv" "FAIL: the pre probe gave no answer (not a verdict)"
hasnt "never wspr-recorder (no pipelines)"  "$T/prechain.lv" "client: wspr-recorder"
has "meteor-scatter's rows said"            "$T/prechain.lv" "UNCHECKED: whether the carry-over owed meteor-scatter a switch file (disabled, but 2 sink.db row(s)"

# ── sp2_unplant_script, hermetic (M-6) ─────────────────────────────────────
echo "sp2_unplant_script:"
UD="$T/ud"; mkdir -p "$UD/run/backup" "$UD/etc" "$UD/dropin.d"
printf 'ORIGINAL=1\n' > "$UD/run/backup/b1"; printf 'LEVERED=1\n' > "$UD/etc/edited.env"
printf 'NEW=1\n' > "$UD/etc/created.env"; : > "$UD/dropin.d/sp2-standin.conf"
cat > "$UD/run/undo" <<X
RESTORE|$UD/etc/edited.env|$UD/run/backup/b1|
REMOVE|$UD/etc/created.env|
DROPIN|psk-recorder@W1AW.service|$UD/dropin.d|1|0|
DROPIN|psk-recorder@N0CALL\\x3dT1.service|$UD/nodir.d|0|1|
UNITFILE|wspr-uploader.service|enabled|1|
X
: > "$STUB_LOG"
SP2_RUN="$UD/run" SP2_SYSTEMCTL="$T/bin/systemctl" bash <(sp2_unplant_script) > "$T/unplant.out" 2>&1
check "an edited file restored" "ORIGINAL=1" "$(cat "$UD/etc/edited.env")"
check "a created file removed" 0 "$( [ -e "$UD/etc/created.env" ] && echo 1 || echo 0)"
check "the drop-in removed" 0 "$( [ -e "$UD/dropin.d" ] && echo 1 || echo 0)"
check "systemd reloaded, once" 1 "$(grep -cx 'daemon-reload' "$STUB_LOG")"
check "an instance that ran restarts on its own process" 1 "$(grep -cx 'restart psk-recorder@W1AW.service' "$STUB_LOG")"
check "an invented instance stops" 1 "$(grep -cxF 'stop psk-recorder@N0CALL\x3dT1.service' "$STUB_LOG")"
check "wspr-uploader enabled again, as it stood" 1 "$(grep -cx 'enable wspr-uploader.service' "$STUB_LOG")"
check "and started again, since it ran" 1 "$(grep -cx 'start wspr-uploader.service' "$STUB_LOG")"
check "no residue" 0 "$(grep -c '^RESIDUE|' "$T/unplant.out")"
check "the undo finished" 1 "$(grep -cx 'END:1' "$T/unplant.out")"
# U-1: only the stand-in file goes; a directory holding another drop-in stays.
UD2="$T/ud2"; mkdir -p "$UD2/run" "$UD2/keep.d"
: > "$UD2/keep.d/sp2-standin.conf"; printf '[Service]\nNice=5\n' > "$UD2/keep.d/operator.conf"
cat > "$UD2/run/undo" <<X
DROPIN|psk-recorder@W1AW.service|$UD2/keep.d|1|0|
UNITFILE|wspr-uploader.service|disabled|0|
X
: > "$STUB_LOG"
SP2_RUN="$UD2/run" SP2_SYSTEMCTL="$T/bin/systemctl" STUB_FAIL=restart bash <(sp2_unplant_script) > "$T/unplant2.out" 2>&1
check "the stand-in file removed" 0 "$( [ -e "$UD2/keep.d/sp2-standin.conf" ] && echo 1 || echo 0)"
check "another drop-in left in place" 1 "$( [ -e "$UD2/keep.d/operator.conf" ] && echo 1 || echo 0)"
# U-2: a failed restart is residue, named.
has "a failed restart is residue" "$T/unplant2.out" "RESIDUE|systemctl restart psk-recorder@W1AW.service|1"
hasnt "and is not said done" "$T/unplant2.out" "RESTARTED|psk-recorder@W1AW.service"
check "wspr-uploader that stood disabled and stopped: left alone" 0 "$(grep -cE '^(enable|start) wspr-uploader' "$STUB_LOG")"
: > "$STUB_LOG"
SP2_RUN="$UD2/run" SP2_SYSTEMCTL="$T/bin/systemctl" STUB_FAIL=daemon-reload bash <(sp2_unplant_script) > "$T/unplant3.out" 2>&1
has "a failed reload is residue" "$T/unplant3.out" "RESIDUE|systemctl daemon-reload|1"
check "no undo record, nothing done" "UNDO:0" "$(SP2_RUN="$T/nothing" SP2_SYSTEMCTL="$T/bin/systemctl" bash <(sp2_unplant_script) | head -1)"

# ── the guest scripts: ASCII only, and bash parses them ────────────────────
echo "the guest scripts:"
printf '%s\n' "$SP2_FILL" > "$T/fill.sh"
check "SP2_FILL holds only ASCII" 0 "$(LC_ALL=C grep -c '[^ -~	]' "$T/fill.sh")"
for s in "sp2_probe_script" "sp2_pre_script" "sp2_plant_script" "sp2_unplant_script" "sp2_state_script before" "sp2_state_script after"; do
    $s > "$T/s.sh"
    check "$s holds only ASCII" 0 "$(LC_ALL=C grep -c '[^ -~	]' "$T/s.sh")"
    bash -n "$T/s.sh" 2>/dev/null; check "$s parses" 0 "$?"
done

if [ "$fail" = 0 ]; then echo "PASS: sink_part2"; else exit 1; fi
