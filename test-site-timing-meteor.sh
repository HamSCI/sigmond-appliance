#!/bin/bash
# test-site-timing-meteor.sh — sigmond-site-timing step 4.5 (meteor-scatter)
# names the config file in the storage form, the unit in the form systemd
# gives it, and people's text in the display form, by asking smd, never tr
# or systemd-escape (sigmond tasks/spec-reporter-id-v372.md §6).  Runs the
# step verbatim against stubbed smd and systemctl.  No root, no network.
#
# systemd-escape(1) turns '-' into \x2d: W1ABC-5 became W1ABC\x2d5, a unit
# nobody enabled.  `tr '/' '='` never upper-cased, so a lower-case reporter
# id split the config file's name from the unit's.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
fail=0

awk '/^# ── 4\.5 meteor-scatter/{f=1} /^# ── 4\.7 ka9q-web/{f=0} f' \
    "$HERE/sigmond-site-timing" \
    | sed -e "s#/etc/sigmond/site-profile.toml#$T/site-profile.toml#g" \
          -e "s#/etc/radio/#$T/radio/#g" \
          -e "s#/etc/meteor-scatter/#$T/meteor-scatter/#g" \
          -e "s#/opt/git/sigmond/meteor-scatter#$T/opt-meteor#g" > "$T/step.sh"
grep -q 'meteor-scatter' "$T/step.sh" || { echo "FAIL: step 4.5 not found in sigmond-site-timing"; exit 1; }
mkdir -p "$T/bin" "$T/radio" "$T/meteor-scatter" "$T/opt-meteor"
: > "$T/radio/radiod@b4.conf"

# The smd stub answers `admin instance canonical` as sigmond does for the ids
# these cases use, and exits 1 with nothing on stdout for anything else —
# which is also what an smd older than v3.72 does with the unknown verb.
cat > "$T/bin/smd" <<EOF
#!/bin/bash
echo "\$*" >> "$T/smd.log"
case "\$*" in
  "admin instance canonical AC0G/B4"|"admin instance canonical ac0g/b4") echo 'AC0G=B4' ;;
  "admin instance canonical --systemd AC0G/B4"|"admin instance canonical --systemd ac0g/b4") echo 'AC0G\x3dB4' ;;
  "admin instance canonical W1ABC-5"|"admin instance canonical --systemd W1ABC-5") echo 'W1ABC-5' ;;
  "admin instance canonical "*) echo "smd: invalid reporter ID" >&2; exit 1 ;;
esac
exit 0
EOF
printf '#!/bin/bash\necho "$*" >> %s/systemctl.log\n' "$T" > "$T/bin/systemctl"
printf '#!/bin/bash\necho "$*" >> %s/escape.log\necho WRONG\n' "$T" > "$T/bin/systemd-escape"
chmod +x "$T/bin/smd" "$T/bin/systemctl" "$T/bin/systemd-escape"

run_case() {  # run_case <name> <reporter_id> <want-conf|-> <want-unit|-> <want-display|->
    local name=$1 rid=$2 conf=$3 unit=$4 disp=$5 ok=1 why=""
    rm -f "${T:?}/smd.log" "${T:?}/systemctl.log" "${T:?}/escape.log" "${T:?}/say.log"
    find "${T:?}/meteor-scatter" -name '*.toml' -delete
    printf '[station]\ncallsign = "AC0G"\ngrid_square = "EM38ww"\n[reporters]\nreporter_id = "%s"\n' \
        "$rid" > "$T/site-profile.toml"
    PATH="$T/bin:$PATH" bash -c "say(){ echo \"\$*\" >> $T/say.log; }; source $T/step.sh"
    if [ -s "$T/escape.log" ]; then ok=0; why="$why; called systemd-escape"; fi
    if [ "$conf" = - ]; then
        if ls "$T"/meteor-scatter/*.toml >/dev/null 2>&1; then ok=0; why="$why; wrote a config"; fi
        if grep -q 'enable' "$T/systemctl.log" 2>/dev/null; then ok=0; why="$why; enabled a unit"; fi
        grep -q 'WARN' "$T/say.log" 2>/dev/null || { ok=0; why="$why; said no WARN"; }
    else
        [ -f "$T/meteor-scatter/$conf" ] || { ok=0; why="$why; no $conf"; }
        grep -qxF "enable --now meteor-scatter@$unit.service" "$T/systemctl.log" 2>/dev/null \
            || { ok=0; why="$why; systemctl got: $(cat "$T/systemctl.log" 2>/dev/null)"; }
        head -1 "$T/meteor-scatter/$conf" 2>/dev/null \
            | grep -qxF "# Per-instance config for meteor-scatter@$disp" \
            || { ok=0; why="$why; header: $(head -1 "$T/meteor-scatter/$conf" 2>/dev/null)"; }
        grep -qxF "reporter_id = \"$disp\"" "$T/meteor-scatter/$conf" 2>/dev/null \
            || { ok=0; why="$why; reporter_id line is not \"$disp\""; }
        grep -qF "meteor-scatter@$disp configured" "$T/say.log" 2>/dev/null \
            || { ok=0; why="$why; said: $(cat "$T/say.log" 2>/dev/null)"; }
    fi
    if [ "$ok" = 1 ]; then echo "  ok   $name"; else echo "  FAIL $name:$why"; fail=1; fi
}

run_case "slash id: AC0G=B4.toml, unit AC0G\\x3dB4, said AC0G/B4" 'AC0G/B4' 'AC0G=B4.toml' 'AC0G\x3dB4' 'AC0G/B4'
run_case "hyphen id keeps its hyphen in the unit name"              'W1ABC-5' 'W1ABC-5.toml' 'W1ABC-5'    'W1ABC-5'
run_case "lower-case id lands on the same file and unit"           'ac0g/b4' 'AC0G=B4.toml' 'AC0G\x3dB4' 'AC0G/B4'
run_case "invalid id (or an old smd): WARN, nothing written"        'AC0G/'   -              -            -

[ "$fail" = 0 ] && echo "PASS: site-timing step 4.5" || { echo "FAILED"; exit 1; }
