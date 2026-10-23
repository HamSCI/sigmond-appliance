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
for fn in sp2_unwrap sp2_tok sp2_probe_script sp2_facts sp2_verdict \
          sp2_plant_script sp2_state_script sp2_fill_facts sp2_lever_verdict; do
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
         switch_view_all-upload.txt switch_view_site-off.txt lever_lines_more.txt SOURCE; do
    [ -s "$FX/$f" ] || { echo "FAIL: fixture $FX/$f missing; run test-fixtures/sink-part2/capture.sh"; exit 1; }
done
echo "fixtures from $(head -1 "$FX/SOURCE")"

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
check "the verdict finds nothing"           ""  "$(cat "$T/good.verdict")"

echo "what the verdict must catch:"
guest up "$FX/pipelines_gate.toml" "$FX/sigmond_gate.toml" 1 "$FX/manifest_step_part2.txt" "$FX/sink_status_all-upload.json"
has "site at upload is not a fresh install" "$T/up.verdict" "the site switch reads 'upload' on a fresh install, not off"
check "and is the only finding" 1 "$(wc -l < "$T/up.verdict")"

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
check "and says nothing else" 1 "$(wc -l < "$T/cut.verdict")"

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

# ── the lever verdict ──────────────────────────────────────────────────────
# The planted psk-recorder instance is the capture's W1AW; the plant, before
# and after replies are the rig's own scripts' format.
P=psk-recorder@W1AW.service
plant(){ cat <<X
PSK:1
PSK_TOPO:1
PSK_ENVSET:0
PSK_SWITCH:1
PSK_START:0
PLANTED|psk-recorder|$P|/etc/psk-recorder/env/W1AW.env
MS:0
${1:-WU:0}
${2:-MAG:0}
END:1
X
}
before(){ cat <<X
UNIT|1|$P|active|1000
UNIT|1|hs-uploader.service|active|500
RADIOD|1|radiod@rx888.service|active|100
UNIT|2|$P|active|1000
UNIT|2|hs-uploader.service|active|500
RADIOD|2|radiod@rx888.service|active|100
LEVER|psk-recorder|direct
WUSTATE|enabled|inactive
MAGEN|bool:true
T0:1790000000
T0MONO:2000
END:1
X
}
after(){ # [psk mono] [psk starts] [radiod mono] [hs-uploader mono] [psk lever] [wu] [mag]
    cat <<X
UNIT|A|$P|active|${1:-3000}
UNIT|A|hs-uploader.service|active|${4:-500}
RADIOD|A|radiod@rx888.service|active|${3:-100}
LEVER|psk-recorder|${5:-server-raw}
WUSTATE|${6:-disabled|inactive}
MAGEN|${7:-bool:false}
STARTS|$P|${2:-1}
STARTS|hs-uploader.service|0
T0:1790000000
END:1
X
}
lv(){ # <name> <plant> <before> <fill facts> <after>
    sp2_lever_verdict "$2" "$3" "$4" "$5" > "$T/$1.lv"
}
plant > "$T/p.txt"; before > "$T/b.txt"; after > "$T/a.txt"
echo "the lever verdict on the capture:"
lv ok "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
check "no FAIL"                       0 "$(nlines "$T/ok.lv" '^FAIL')"
check "three levers this nest cannot show, said" 3 "$(nlines "$T/ok.lv" '^UNCHECKED: the \(meteor-scatter\|wspr-uploader\|mag-recorder\) lever')"

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
after 3000 1 100 500 direct > "$T/a5.txt"; lv lever "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/a5.txt"
has "a lever not on disk" "$T/lever.lv" "FAIL: psk-recorder's env file reads 'direct' after the fill"
fillout "$T/fillrc.out" 1 "$FX/sink_fill_part2.txt"; through "$T/fillrc.out" "$T/fillrc.txt"
sp2_fill_facts "$T/fillrc.txt" > "$T/fillrc.facts"; lv rc "$T/p.txt" "$T/b.txt" "$T/fillrc.facts" "$T/a.txt"
has "a failed fill" "$T/rc.lv" "FAIL: smd sink fill --reason rig exited 1"
grep -v '^END:1$' "$T/a.txt" > "$T/acut.txt"; lv cut "$T/p.txt" "$T/b.txt" "$T/fill.facts" "$T/acut.txt"
has "a cut reply is not a verdict" "$T/cut.lv" "gave no answer (guest exec failed; not a verdict)"
check "and says nothing else" 1 "$(wc -l < "$T/cut.lv")"
grep -v '^RADIOD' "$T/b.txt" > "$T/bnr.txt"; grep -v '^RADIOD' "$T/a.txt" > "$T/anr.txt"
lv noradiod "$T/p.txt" "$T/bnr.txt" "$T/fill.facts" "$T/anr.txt"
has "no radiod in the nest is said, not passed" "$T/noradiod.lv" "UNCHECKED: radiod's start time across the fill"
hasnt "with radiod running, nothing unchecked about it" "$T/ok.lv" "radiod's start time"
# The pre-fill reads disagree: the restart count cannot be judged.
sed "s/^UNIT|2|$P|active|1000/UNIT|2|$P|active|1500/" "$T/b.txt" > "$T/bun.txt"
lv unsteady "$T/p.txt" "$T/bun.txt" "$T/fill.facts" "$T/a.txt"
has "an unsteady unit is said, not judged" "$T/unsteady.lv" "UNCHECKED: the restart count of $P"

echo "wspr-uploader and the mag fallback planted:"
plant "$(printf 'WU:1\nWU_ENABLE:0\nWU_SWITCH:1')" "$(printf 'MAG:1\nMAG_SET:0\nMAG_SWITCH:1')" > "$T/pwm.txt"
lv wm "$T/pwm.txt" "$T/b.txt" "$T/fill2.facts" "$T/a.txt"
hasnt "with their lines, no wspr-uploader finding" "$T/wm.lv" "wspr-uploader"
hasnt "with their lines, no mag finding"           "$T/wm.lv" "mag-recorder"
lv wmmiss "$T/pwm.txt" "$T/b.txt" "$T/fill.facts" "$T/a.txt"
has "the fill not disabling wspr-uploader" "$T/wmmiss.lv" "FAIL: smd sink fill did not stop and disable wspr-uploader.service"
has "the fill not writing the mag lever"   "$T/wmmiss.lv" "FAIL: smd sink fill did not write the mag-recorder lever"
after 3000 1 100 500 server-raw 'enabled|inactive' "'false'" > "$T/a6.txt"
lv wmdisk "$T/pwm.txt" "$T/b.txt" "$T/fill2.facts" "$T/a6.txt"
has "wspr-uploader still enabled" "$T/wmdisk.lv" "FAIL: wspr-uploader.service reads"
has "mag's enabled a string"      "$T/wmdisk.lv" "not the boolean false"

# ── the guest scripts: ASCII only, and bash parses them ────────────────────
echo "the guest scripts:"
printf '%s\n' "$SP2_FILL" > "$T/fill.sh"
check "SP2_FILL holds only ASCII" 0 "$(LC_ALL=C grep -c '[^ -~	]' "$T/fill.sh")"
for s in "sp2_probe_script" "sp2_plant_script" "sp2_state_script before" "sp2_state_script after"; do
    $s > "$T/s.sh"
    check "$s holds only ASCII" 0 "$(LC_ALL=C grep -c '[^ -~	]' "$T/s.sh")"
    bash -n "$T/s.sh" 2>/dev/null; check "$s parses" 0 "$?"
done

if [ "$fail" = 0 ]; then echo "PASS: sink_part2"; else exit 1; fi
