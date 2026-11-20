#!/bin/bash
# test-bare-metal-lib.sh -- the bare-metal install test (test-bare-metal.sh)
# and its record helpers (bare-metal-lib.sh).  Hermetic: a scratch sigmond
# repo with a local bare origin, built from the sibling checkout's
# lib/sigmond; fakes for sudo, qemu, ssh and scp.  No VM, no network.
#
#   bash test-bare-metal-lib.sh            (SIGMOND_REPO defaults to ../sigmond)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SIGMOND_REPO="${SIGMOND_REPO:-$HERE/../sigmond}"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1${2:+ -- $2}"; fail=$((fail+1)); }

T="$(mktemp -d)"
trap 'pkill -P $$ 2>/dev/null; [ -s "$T/vm.pid" ] && kill "$(cat "$T/vm.pid")" 2>/dev/null; rm -rf "$T"' EXIT
[ -d "$SIGMOND_REPO/lib/sigmond" ] || { echo "FAIL: no lib/sigmond under $SIGMOND_REPO"; exit 1; }
[ -f "$SIGMOND_REPO/lib/sigmond/bare_metal_doc.py" ] \
    || { echo "FAIL: $SIGMOND_REPO lacks sigmond.bare_metal_doc (point SIGMOND_REPO at the release-home worktree)"; exit 1; }

C1="$(printf c1 | sha1sum | cut -c1-40)"
C2="$(printf c2 | sha1sum | cut -c1-40)"
DG="$(printf d | sha256sum | cut -c1-64)"
key() { awk -F': *' -v k="$2" '$1==k {sub(/^[^:]*: */,""); print; exit}' "$1"; }

# shellcheck disable=SC1091
if ! . "$HERE/bare-metal-lib.sh" 2>/dev/null; then
    bad "bare-metal-lib.sh sources" "missing or broken"
fi

# ── bm_record: every C2 key, and the pass rule ──
D="$T/records"; mkdir -p "$D"
p="$(BM_NOW_EPOCH=1795000000 bm_record "$D" v3.94 "$C1" "$DG" 0 2 0 2>&1)"; rc=$?
if [ "$rc" = 0 ] && [ -f "$p" ]; then
    ok "bm_record writes a record and prints its path"
    [ "$(basename "$p")" = "v3.94-20261118T110640Z.record" ] \
        && ok "the record is named <version>-<YYYYmmddTHHMMSSZ>.record" \
        || bad "record name" "$(basename "$p")"
    for k in bare_metal_record version sigmond_commit doc_commands_sha256 \
             release_list_check smd_check_exit radiod_consumers result finished_utc; do
        grep -q "^$k: " "$p" || bad "record key $k" "missing"
    done
    [ "$(key "$p" bare_metal_record)" = 1 ] && [ "$(key "$p" version)" = v3.94 ] \
        && [ "$(key "$p" sigmond_commit)" = "$C1" ] && [ "$(key "$p" doc_commands_sha256)" = "$DG" ] \
        && [ "$(key "$p" finished_utc)" = 2026-11-18T11:06:40Z ] \
        && ok "bm_record carries every C2 key with its value" \
        || bad "record values" "$(tr '\n' ' ' < "$p")"
else
    bad "bm_record (0,2,0)" "rc=$rc out=$p"
fi

i=0
for args in "0 2 0:PASS:PASS:2:PASS" "0 0 0:PASS:PASS:0:PASS" \
            "1 0 0:FAIL:PASS:0:FAIL" "0 1 0:PASS:PASS:1:FAIL" "0 0 1:PASS:FAIL:0:FAIL" \
            "0 -1 1:PASS:FAIL:-1:FAIL" "2 0 0:FAIL:PASS:0:FAIL"; do
    IFS=: read -r trio lst cons ex res <<< "$args"
    i=$((i+1))
    # shellcheck disable=SC2086
    p="$(BM_NOW_EPOCH=$((1795001000 + i)) bm_record "$D" v3.94 "$C1" "$DG" $trio 2>/dev/null)"
    if [ -f "$p" ] && [ "$(key "$p" release_list_check)" = "$lst" ] \
        && [ "$(key "$p" radiod_consumers)" = "$cons" ] \
        && [ "$(key "$p" smd_check_exit)" = "$ex" ] && [ "$(key "$p" result)" = "$res" ]; then
        ok "bm_record ($trio) -> result: $res"
    else
        bad "bm_record ($trio)" "$( [ -f "$p" ] && tr '\n' ' ' < "$p" || echo "no record: $p")"
    fi
done

BM_NOW_EPOCH=1795002000 bm_record "$D" v3.94 "$C1" "$DG" 0 0 0 >/dev/null 2>&1
BM_NOW_EPOCH=1795002000 bm_record "$D" v3.94 "$C1" "$DG" 1 0 0 >/dev/null 2>&1 \
    && bad "bm_record overwrote an existing record" || ok "bm_record never overwrites a record"
bm_record "$D" v3.94 "${C1:0:12}" "$DG" 0 0 0 >/dev/null 2>&1 \
    && bad "bm_record took a short commit" || ok "bm_record refuses a short commit"
bm_record "$D" v3.94 "$C1" "$DG" 0 x 0 >/dev/null 2>&1 \
    && bad "bm_record took a non-integer check exit" || ok "bm_record refuses a non-integer check exit"

# ── bm_newest: the newest by the stamp in the NAME, as bless gate 10 picks ──
N="$T/newest"; mkdir -p "$N"
a="$(BM_NOW_EPOCH=1795010000 bm_record "$N" v3.94 "$C1" "$DG" 0 0 0 2>/dev/null)"
b="$(BM_NOW_EPOCH=1795020000 bm_record "$N" v3.94 "$C1" "$DG" 0 1 0 2>/dev/null)"
BM_NOW_EPOCH=1795030000 bm_record "$N" v3.94 "$C2" "$DG" 0 0 0 >/dev/null 2>&1
BM_NOW_EPOCH=1795040000 bm_record "$N" v3.95 "$C1" "$DG" 0 0 0 >/dev/null 2>&1
out="$(bm_newest "$N" v3.94 "$C1")"
[ "$out" = "$b" ] && ok "bm_newest picks the later of two (another commit and version ignored)" \
    || bad "bm_newest later of two" "got '$out' want '$b'"
# A record whose finished_utc reads later but whose name stamp is earlier
# loses: gate 10 orders by name.
sed -i 's/^finished_utc: .*/finished_utc: 2030-01-01T00:00:00Z/' "$a"
out="$(bm_newest "$N" v3.94 "$C1")"
[ "$out" = "$b" ] && ok "bm_newest orders by the name's stamp, not finished_utc" \
    || bad "bm_newest by name" "got '$out'"
out="$(bm_newest "$N" v3.94 "$C2")"
[ "$(key "$out" sigmond_commit 2>/dev/null)" = "$C2" ] && ok "bm_newest matches the commit" \
    || bad "bm_newest commit" "got '$out'"
bm_newest "$N" v3.93 "$C1" >/dev/null 2>&1 && bad "bm_newest found a record for an absent version" \
    || ok "bm_newest fails when no record matches"

# ── a scratch sigmond with a local bare origin ──
S="$T/sigmond"; O="$T/origin.git"; mkdir -p "$S/lib" "$S/release" "$S/docs"
cp -r "$SIGMOND_REPO/lib/sigmond" "$S/lib/"
find "$S/lib" -name __pycache__ -prune -exec rm -rf {} +
g() { git -C "$S" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
ROWS="callhash codar-sounder ft8_lib gmag-webui gpsdo-monitor hamsci-dsp hamsci-physics
hf-tec hf-timestd hfdl-recorder hs-uploader igmp-querier ka9q-python ka9q-radio ka9q-web
mag-recorder meteor-scatter onion psk-recorder sigmond-proxmox sigmond-rac station-web
superdarn-sounder ubersdr_wsprd wsjtx wspr-recorder"
{
    echo '# sigmond release list -- fixture'
    echo 'version = "v3.94"'
    echo
    echo '[components]'
    for r in $ROWS; do echo "$r = \"$(printf '%s' "$r" | sha1sum | cut -c1-40)\""; done
} > "$S/release/components.toml"
doc() {   # doc <with-checkout 1|0>
    printf '%s\n' '# Installing' '' '## 2. Install sigmond' '' '```bash' \
        'git clone https://github.com/HamSCI/sigmond /opt/git/sigmond/sigmond' \
        'cd /opt/git/sigmond/sigmond'
    [ "$1" = 1 ] && echo 'git checkout v3.94'
    printf '%s\n' './install.sh' '```' '' '## 3. Bring up the station' '' '```bash' \
        'smd bringup dasi2 --callsign AC0G --grid EM38ww --reporter AC0G/S \' \
        '                  --release-list /opt/git/sigmond/sigmond/release/components.toml \' \
        '                  --psws-station-id S000418' '```' '' '## 4. Next' ''
}
doc 1 > "$S/docs/install-bare-metal.md"
g init -q -b main
g add lib release docs; g commit -q -m "v3.94 list and doc"
SC="$(g rev-parse HEAD)"
echo "$SC" > "$T/sc"   # what the fake VM's checkout reports by default
git init -q --bare "$O"
g remote add origin "$O"; g push -q origin main

# ── fakes: sudo, qemu, qemu-img, ssh, scp, sleep, pkill ──
F="$T/fake"; mkdir -p "$F" "$T/vmfs"
cat > "$F/sudo" <<'EOF'
#!/bin/bash
echo "sudo $*" >> "$FAKE_LOG"
exec "$@"
EOF
cat > "$F/qemu-system-x86_64" <<'EOF'
#!/bin/bash
echo "qemu $*" >> "$FAKE_LOG"
echo "$*" > "$FAKE_DIR/qemu.args"
pidf=""; prev=""
for a in "$@"; do [ "$prev" = -pidfile ] && pidf="$a"; prev="$a"; done
bash -c 'exec -a "qemu-fake -name baremetal" /bin/sleep 300' </dev/null >/dev/null 2>&1 &
echo $! > "$FAKE_DIR/vm.pid"
[ -n "$pidf" ] && echo $! > "$pidf"
touch "$FAKE_DIR/booted"
EOF
cat > "$F/qemu-img" <<'EOF'
#!/bin/bash
echo "qemu-img $*" >> "$FAKE_LOG"
EOF
cat > "$F/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$F/pkill" <<'EOF'
#!/bin/bash
echo "pkill $*" >> "$FAKE_LOG"
EOF
cat > "$F/scp" <<'EOF'
#!/bin/bash
echo "scp $*" >> "$FAKE_LOG"
src=""; for a in "$@"; do case "$a" in -*) ;; *) [ -f "$a" ] && src="$a" ;; esac; done
[ -n "$src" ] && cp "$src" "$FAKE_DIR/vmfs/$(basename "$src")"
exit 0
EOF
cat > "$F/ssh" <<'EOF'
#!/bin/bash
cmd="${!#}"
echo "ssh $cmd" >> "$FAKE_DIR/ssh.log"
if [ ! -e "$FAKE_DIR/booted" ] || [ "${FAKE_NEVER_UP:-0}" = 1 ]; then exit 255; fi
case "$cmd" in
    true) exit 0 ;;
    *"uname -r"*) echo "6.12.57+deb13-amd64" ;;
    *"grep -q 'linux-image.*cloud'"*) exit 1 ;;
    *"/sys/bus/usb/devices"*) [ "${FAKE_NO_USB:-0}" = 1 ] || echo /sys/bus/usb/devices/usb1 ;;
    *rac-endpoint.env*) echo PIN:OK ;;
    *bm-install.sh*) echo "install ran"; exit "${FAKE_INSTALL_RC:-0}" ;;
    *"cat /tmp/bm-sigmond-head"*) [ "${FAKE_NO_HEAD:-0}" = 1 ] && exit 1
        echo "${FAKE_HEAD:-$(cat "$FAKE_DIR/sc")}" ;;
    *bm-bringup.sh*) echo "bringup ran"; exit "${FAKE_BRINGUP_RC:-0}" ;;
    *"release-list --check"*) echo "release list v3.94: matches (live)"; exit "${FAKE_LIST_RC:-0}" ;;
    *"check --json"*) cat "$FAKE_CHECK_JSON"; exit "${FAKE_CHECK_RC:-2}" ;;
    *"smd check"*) echo "text check"; exit "${FAKE_CHECK_RC:-2}" ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$F"/*

line() { printf '{"label": "%s", "mark": "%s", "text": "%s"}' "$1" "$2" "$3"; }
cj() {   # cj <psk-mark>: a check --json with four radiod consumers
    local w='radiod is installed, not running; waits on dormant radiod'
    printf '{"lines": [%s, %s, %s, %s, %s], "verdict": "WAIT"}\n' \
        "$(line PSK "$1" "$w")" "$(line WSPR wait "$w")" "$(line 'meteor scatter' wait "$w")" \
        "$(line GRAPE wait "$w")" "$(line sigmond ok fine)"
}
cj wait > "$T/good.json"
cj FAIL > "$T/bad.json"

R="$T/rig"; mkdir -p "$R/v3" "$R/vmbuild" "$R/build"
: > "$R/vmbuild/debian-13-genericcloud-amd64.qcow2"; : > "$R/vmbuild/seed.iso"; : > "$R/build/applkey"
echo 0 > "$T/runs"
run() {   # run <args...>: test-bare-metal.sh with the fakes on PATH, each run its own second
    local RUNS; RUNS=$(( $(cat "$T/runs") + 1 )); echo "$RUNS" > "$T/runs"   # $(run) is a subshell
    rm -f "$T/booted" "$T/ssh.log" "$T/qemu.args"; : > "$T/fake.log"
    PATH="$F:$PATH" FAKE_LOG="$T/fake.log" FAKE_DIR="$T" \
        APPLIANCE_RIG_ROOT="$R" RIG_DIR="$R/v3" SIGMOND_REPO="$S" \
        APPLIANCE_VMBUILD_DIR="$R/vmbuild" APPLIANCE_BUILD_DIR="$R/build" \
        APPLIANCE_BUILD_MEM=4096 BM_NOW_EPOCH=$((1795100000 + RUNS)) FAKE_CHECK_JSON="${FAKE_CHECK_JSON:-$T/good.json}" \
        bash "$HERE/test-bare-metal.sh" "$@" 2>&1
}

bash -n "$HERE/test-bare-metal.sh" 2>/dev/null && ok "bash -n test-bare-metal.sh" \
    || bad "bash -n test-bare-metal.sh"

# ── --dry-run: both parts and the record path, no VM ──
out="$(run v3.94 --commit "$SC" --dry-run)"; rc=$?
[ "$rc" = 0 ] && ok "--dry-run exits 0" || bad "--dry-run rc" "rc=$rc: $out"
grep -qx "git checkout $SC" <<< "$out" && ok "--dry-run prints 'git checkout <sha>'" \
    || bad "--dry-run checkout line" "$out"
grep -q -- '--non-interactive' <<< "$out" && ok "--dry-run prints the bring-up with --non-interactive" \
    || bad "--dry-run bring-up" "$out"
grep -q 'N0CALL' <<< "$out" && ! grep -q 'S000418' <<< "$out" \
    && ok "--dry-run bring-up carries the test identity, no PSWS ids" || bad "--dry-run identity" "$out"
grep -q "$R/v3/bare-metal/v3.94-[0-9]\{8\}T[0-9]\{6\}Z.record" <<< "$out" \
    && ok "--dry-run prints the planned record path" || bad "--dry-run record path" "$out"
grep -q 'qemu\|sudo\|scp' "$T/fake.log" || [ -s "$T/ssh.log" ] \
    && bad "--dry-run touched the VM" "$(cat "$T/fake.log" "$T/ssh.log" 2>/dev/null)" \
    || ok "--dry-run does no VM work"
[ -e "$R/v3/bare-metal" ] && [ -n "$(ls "$R/v3/bare-metal" 2>/dev/null)" ] \
    && bad "--dry-run wrote into bare-metal/" "$(ls "$R/v3/bare-metal")" || ok "--dry-run writes no record or log"

# C4: no --commit reads golden-v3-sigmond-commit.txt
echo "$SC" > "$R/v3/golden-v3-sigmond-commit.txt"
out="$(run v3.94 --dry-run)"; rc=$?
[ "$rc" = 0 ] && grep -qx "git checkout $SC" <<< "$out" \
    && ok "without --commit the golden VM's commit (C4) is tested" || bad "C4 default" "rc=$rc: $out"
# A short --commit resolves to the full commit
out="$(run v3.94 --commit "${SC:0:10}" --dry-run)"
grep -qx "git checkout $SC" <<< "$out" && ok "a short --commit resolves to 40 hex" || bad "short commit" "$out"

out="$(run v3.95 --commit "$SC" --dry-run)"; rc=$?
[ "$rc" != 0 ] && grep -q 'v3.94' <<< "$out" && ok "a version the list does not name refuses, naming the list's" \
    || bad "version mismatch" "rc=$rc: $out"

# A commit not on origin refuses: the VM clones from origin and could not check it out.
g commit -q --allow-empty -m "local only"
LOCAL="$(g rev-parse HEAD)"
out="$(run v3.94 --commit "$LOCAL" --dry-run)"; rc=$?
[ "$rc" != 0 ] && grep -qi 'origin' <<< "$out" && ok "a commit not on origin refuses" \
    || bad "unpushed commit" "rc=$rc: $out"
g reset -q --hard "$SC"

# ── full run, fakes for the VM ──
mkdir -p "$R/v3/bare-metal"
newest_rec() { ls "$R/v3/bare-metal"/v3.94-*.record 2>/dev/null | LC_ALL=C sort | tail -1; }
nrec() { ls "$R/v3/bare-metal"/*.record 2>/dev/null | wc -l; }
want_dg="$(PYTHONPATH="$S/lib" python3 -m sigmond.bare_metal_doc digest --doc "$S/docs/install-bare-metal.md")"

out="$(run v3.94 --commit "$SC")"; rc=$?
r="$(newest_rec)"
[ "$rc" = 0 ] && ok "a passing run exits 0" || bad "passing run rc" "rc=$rc: $(tail -20 <<< "$out")"
if [ -n "$r" ]; then
    [ "$(key "$r" result)" = PASS ] && [ "$(key "$r" sigmond_commit)" = "$SC" ] \
        && [ "$(key "$r" smd_check_exit)" = 2 ] && [ "$(key "$r" doc_commands_sha256)" = "$want_dg" ] \
        && ok "the record reads PASS at the commit, exit 2, the doc's digest" \
        || bad "passing record" "$(tr '\n' ' ' < "$r")"
    [ "$(bm_newest "$R/v3/bare-metal" v3.94 "$SC")" = "$r" ] && ok "bm_newest finds the run's record" \
        || bad "bm_newest after run"
else
    bad "passing run wrote no record" "$(tail -20 <<< "$out")"
fi
ls "$R/v3/bare-metal"/v3.94-*.log >/dev/null 2>&1 && ok "the run logs to bare-metal/<version>-<stamp>.log" \
    || bad "no run log"
args="$(cat "$T/qemu.args" 2>/dev/null)"
grep -q -- '-name baremetal' <<< "$args" && grep -q 'hostfwd=tcp:127.0.0.1:5558-:22' <<< "$args" \
    && grep -q 'bare-metal-test.qcow2' <<< "$args" && grep -q "$R/vmbuild/seed.iso" <<< "$args" \
    && ok "qemu boots -name baremetal, its own disk, the seed iso, ssh on 5558" || bad "qemu args" "$args"
grep -q -- '-device qemu-xhci' <<< "$args" && ok "the VM carries a USB controller (qemu-xhci)" \
    || bad "no qemu-xhci" "$args"
grep -q 'goldenv3\|golden-v3\|5557' "$T/fake.log" "$T/ssh.log" 2>/dev/null \
    && bad "the run touched the golden VM" || ok "the run never touches goldenv3"
grep -q '^pkill' "$T/fake.log" && bad "the run used pkill" || ok "no pkill -f (the VM stops by pidfile)"
grep -q 'qemu-img resize .*bare-metal-test.qcow2 40G' "$T/fake.log" && ok "the disk grows to 40G" \
    || bad "resize" "$(grep qemu-img "$T/fake.log")"
grep -q "rac-endpoint.env" "$T/ssh.log" && grep -q 'SIGMOND_RAC_SERVER=127.0.0.1' "$T/ssh.log" \
    && ok "RAC pinned to 127.0.0.1 in the VM" || bad "RAC pin" "$(cat "$T/ssh.log")"
pin_n="$(grep -n 'rac-endpoint.env' "$T/ssh.log" | head -1 | cut -d: -f1)"
br_n="$(grep -n 'bm-bringup.sh' "$T/ssh.log" | head -1 | cut -d: -f1)"
in_n="$(grep -n 'bm-install.sh' "$T/ssh.log" | head -1 | cut -d: -f1)"
[ -n "$pin_n" ] && [ -n "$in_n" ] && [ -n "$br_n" ] && [ "$pin_n" -lt "$in_n" ] && [ "$in_n" -lt "$br_n" ] \
    && ok "pin, then install, then bring-up in a later ssh session" || bad "order" "pin=$pin_n in=$in_n br=$br_n"
grep -q 'bm-install.sh.*bm-bringup.sh\|bm-bringup.sh.*bm-install.sh' "$T/ssh.log" \
    && bad "install and bring-up shared an ssh session" || ok "install and bring-up run in separate sessions"
grep -qx "git checkout $SC" "$T/vmfs/bm-install.sh" 2>/dev/null \
    && ok "the VM's install part checks out the commit" || bad "install part in VM" "$(cat "$T/vmfs/bm-install.sh" 2>&1)"
grep -q -- '--non-interactive' "$T/vmfs/bm-bringup.sh" 2>/dev/null \
    && ok "the VM's bring-up part is the doc's, non-interactive" || bad "bringup part in VM"
pid="$(cat "$T/vm.pid" 2>/dev/null)"
[ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && ok "the VM is stopped at the end" || bad "VM still running" "pid=$pid"

# a radiod consumer FAILs -> record FAIL, exit 1
before="$(nrec)"
out="$(FAKE_CHECK_JSON="$T/bad.json" FAKE_CHECK_RC=1 run v3.94 --commit "$SC")"; rc=$?
r="$(newest_rec)"
[ "$rc" = 1 ] && [ "$(nrec)" -gt "$before" ] && [ "$(key "$r" result)" = FAIL ] \
    && [ "$(key "$r" radiod_consumers)" = FAIL ] && [ "$(key "$r" smd_check_exit)" = 1 ] \
    && ok "a failing check writes a FAIL record and exits 1" || bad "failing check" "rc=$rc $(tr '\n' ' ' < "$r")"
grep -q 'PSK' <<< "$out" && ok "the judge's reason reaches the output" || bad "judge reason" "$(tail <<< "$out")"
pid="$(cat "$T/vm.pid" 2>/dev/null)"
! kill -0 "$pid" 2>/dev/null && ok "the VM is stopped after a FAIL" || bad "VM left running after FAIL"

# release list mismatch -> FAIL
out="$(FAKE_LIST_RC=1 run v3.94 --commit "$SC")"; rc=$?
r="$(newest_rec)"
[ "$rc" = 1 ] && [ "$(key "$r" release_list_check)" = FAIL ] && [ "$(key "$r" result)" = FAIL ] \
    && ok "a release-list mismatch writes FAIL" || bad "list mismatch" "rc=$rc $(tr '\n' ' ' < "$r")"

# the doc's bring-up fails -> FAIL record, smd check never judged
out="$(FAKE_BRINGUP_RC=3 run v3.94 --commit "$SC")"; rc=$?
r="$(newest_rec)"
[ "$rc" = 1 ] && [ "$(key "$r" result)" = FAIL ] && [ "$(key "$r" smd_check_exit)" = -1 ] \
    && ok "a failed doc step writes FAIL (smd_check_exit -1)" || bad "bring-up failure" "rc=$rc $(tr '\n' ' ' < "$r")"
grep -q 'check --json' "$T/ssh.log" && bad "judged smd check after a failed bring-up" \
    || ok "no verdict taken after a failed doc step"

grep -qx "git -C /opt/git/sigmond/sigmond rev-parse HEAD > /tmp/bm-sigmond-head" "$T/vmfs/bm-install.sh" 2>/dev/null \
    && ok "the VM's install part writes the checkout's commit" || bad "no head line in the install part" "$(cat "$T/vmfs/bm-install.sh" 2>&1)"

# the checkout in the VM stands at another commit -> no record (a rig fault)
before="$(nrec)"
out="$(FAKE_HEAD="$(printf '9%.0s' {1..40})" run v3.94 --commit "$SC")"; rc=$?
[ "$rc" != 0 ] && [ "$(nrec)" = "$before" ] && grep -q "not $SC" <<< "$out" \
    && ok "a VM checkout at another commit writes no record, exits non-zero" || bad "wrong head" "rc=$rc $(tail -5 <<< "$out")"
grep -q 'check --json' "$T/ssh.log" && bad "judged smd check after a wrong head" \
    || ok "no verdict taken after a wrong head"
before="$(nrec)"
out="$(FAKE_NO_HEAD=1 run v3.94 --commit "$SC")"; rc=$?
[ "$rc" != 0 ] && [ "$(nrec)" = "$before" ] && grep -q "stands at 'nothing'" <<< "$out" \
    && ok "a VM with no head file writes no record" || bad "no head file" "rc=$rc $(tail -5 <<< "$out")"
pid="$(cat "$T/vm.pid" 2>/dev/null)"
! kill -0 "$pid" 2>/dev/null && ok "the VM is stopped after a wrong head" || bad "VM left running after wrong head"

# the VM never answers ssh -> no record (not a verdict on the release)
before="$(nrec)"
out="$(FAKE_NEVER_UP=1 run v3.94 --commit "$SC")"; rc=$?
[ "$rc" != 0 ] && [ "$(nrec)" = "$before" ] && ok "a VM that never answers writes no record, exits non-zero" \
    || bad "dead VM" "rc=$rc"
pid="$(cat "$T/vm.pid" 2>/dev/null)"
! kill -0 "$pid" 2>/dev/null && ok "the VM is stopped when ssh never comes up" || bad "VM left running"

# no USB root hub in the VM -> no record (the verdict would always read FAIL)
before="$(nrec)"
out="$(FAKE_NO_USB=1 run v3.94 --commit "$SC")"; rc=$?
[ "$rc" != 0 ] && [ "$(nrec)" = "$before" ] && grep -qi 'usb' <<< "$out" \
    && ok "a VM with no USB bus stops before the doc runs, no record" || bad "no USB" "rc=$rc $(tail -5 <<< "$out")"

# ── the doc at origin/main without the checkout line refuses, naming it ──
doc 0 > "$S/docs/install-bare-metal.md"
g commit -q -am "doc drops the checkout"; g push -q origin main
out="$(run v3.94 --commit "$SC" --dry-run)"; rc=$?
[ "$rc" != 0 ] && grep -q 'git checkout v3.94' <<< "$out" \
    && ok "a doc without 'git checkout v3.94' refuses, naming the line" || bad "doc lacks checkout" "rc=$rc: $out"

echo "--- $pass passed, $fail FAIL"
[ "$fail" = 0 ]
