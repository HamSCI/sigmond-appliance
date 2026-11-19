#!/bin/bash
# test-location-check-lock.sh -- sigmond-location-check skips its tick while
# smd's lifecycle lock is held, and acts when it is free.  No VM, no root.
#
# Why: `smd align --apply` started the location-check timer before its own
# bring-up, and the first tick (OnActiveSec=2min) re-rendered the config and
# restarted the recorders in the middle of it (final review I1, 2026-11-19).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/sigmond-location-check"
command -v flock >/dev/null || { echo "FAIL: flock not found"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/gpsdo"
# Made-up position; the profile sits ~0.5 deg away, so the script must move it.
cat > "$T/gpsdo/a.json" <<'J'
{"health": {"latitude": 10.5, "longitude": 20.25, "gps_fix": "3D", "sats_used": 8, "fix_age_sec": 5}}
J
for n in smd systemctl; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$n" "$T" > "$T/bin/$n"
done
printf '#!/bin/bash\ncat >/dev/null\n' > "$T/bin/systemd-cat"
chmod +x "$T/bin/"*
profile() {
    printf '[station]\ncallsign = "N0CALL"\nlatitude = 11.0\nlongitude = 20.25\ngrid_square = "KK00dm"\nlocation_source = "operator"\n' > "$T/sp.toml"
    rm -f "$T/calls"
}
run() {
    PATH="$T/bin:$PATH" SIGMOND_SITE_PROFILE="$T/sp.toml" SIGMOND_GPSDO_DIR="$T/gpsdo" \
        SIGMOND_LIFECYCLE_LOCK="$T/lifecycle.lock" bash "$SRC"
}
fail=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fail=1; fi; }

# 1. lock held (as smd's lifecycle_lock holds it: flock LOCK_EX on the file)
profile
( flock -n 8 || exit 3; run ) 8>>"$T/lifecycle.lock"
check "lock held: script exits 0" '[ $? -eq 0 ]'
check "lock held: no smd or systemctl call" '[ ! -e "$T/calls" ]'
check "lock held: profile unchanged" 'grep -q "^latitude = 11.0" "$T/sp.toml"'
check "lock held: no backup written" '! ls "$T"/sp.toml.bak-location-* >/dev/null 2>&1'

# 2. lock free: the position moves and the recorders restart
profile
run
check "lock free: profile moved" 'grep -q "^latitude = 10.5" "$T/sp.toml"'
check "lock free: recorders restarted" 'grep -q "systemctl try-restart" "$T/calls"'

# 3. positive control: the lock path the script uses is smd's
check "default lock is smd's" 'grep -q "/var/lib/sigmond/lifecycle.lock" "$SRC"'

[ $fail -eq 0 ] && echo "PASS" || echo "FAIL"
exit $fail
