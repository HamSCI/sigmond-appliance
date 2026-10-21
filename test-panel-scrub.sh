#!/bin/bash
# test-panel-scrub.sh — ssh logins always see the panel.
#
# AC1SN (DASI-017), after the 2026-10-18 power loss: /etc/motd held 2004 NUL
# bytes just above the panel.  pam_motd prints the file as a C string and stops
# at the first NUL, so every ssh login -- including over the RAC -- showed the
# Debian notice, the old install banner, and then nothing.  The console
# (/etc/issue) was intact, so the panel looked fine to anyone standing there.
# sigmond-issue only ever replaces its own marked block, so damage outside it
# was never repaired.
#
# Also: firstboot appended an install banner to /etc/motd --
#     ==== Sigmond appliance v3.69 ====
#     Decoder VM: 100 (sigmond-decoder-v3-69)   Wizard: sigmond-setup
# which repeated the panel's header and told an operator nothing (rob,
# 2026-10-20).  firstboot no longer writes it; the scrub removes it from hosts
# that already have it.
#
# Pass a different firstboot-v3.sh as $1 to run this against a mutant.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$FB" "$TMP" <<'PYX'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text(); t = sys.argv[2]
m = re.search(r"cat > /usr/local/sbin/sigmond-issue <<'ISSEOF'\n(.*?)\nISSEOF\n", s, re.S)
if not m: raise SystemExit("could not extract sigmond-issue")
issue = m.group(1)
pathlib.Path(t, "issue.sh").write_text(issue)
f = re.search(r"\n(_scrub_panel_file\(\)\{\n.*?\n\})\n", issue, re.S)
pathlib.Path(t, "scrub.sh").write_text(f.group(1) + "\n" if f else "")
# firstboot's own code outside the heredocs it writes, comments out.
pathlib.Path(t, "fb.code").write_text(
    "\n".join(l for l in s.split("\n") if not l.lstrip().startswith("#")))
PYX

echo "── the scrub exists and both panel writers call it first ─────────"
[ -s "$TMP/scrub.sh" ] && ok "sigmond-issue defines _scrub_panel_file" \
    || bad "no _scrub_panel_file in sigmond-issue" "damage outside the panel block is never repaired"
loops=$(grep -c '^for f in /etc/issue /etc/motd; do$' "$TMP/issue.sh")
called=$(awk '/^for f in \/etc\/issue \/etc\/motd; do$/{inl=1; seen=0; next}
              inl && /_scrub_panel_file "\$f"/{seen=1}
              inl && /sed -i .\/\^════ Sigmond appliance/{ if(seen) n++; inl=0 }
              END{print n+0}' "$TMP/issue.sh")
[ "$loops" -ge 2 ] && [ "$called" = "$loops" ] \
    && ok "all $loops write loops scrub before they replace the block" \
    || bad "a write loop rewrites /etc/motd without scrubbing it ($called of $loops)" \
           "a NUL left above the panel hides it from every ssh login"

echo "── it repairs AC1SN's /etc/motd ─────────────────────────────────"
{
  printf '\nThe programs included with the Debian GNU/Linux system are free software;\n\n'
  printf '  ==== Sigmond appliance v3.69 ====\n'
  printf '  Decoder VM: 100 (sigmond-decoder-v3-69)   Wizard: sigmond-setup\n'
  head -c 2004 /dev/zero; printf '\n\n'
  printf '════ Sigmond appliance v3.69 — station AC1SN ════\n LAN   gateway 192.168.1.1 responds\n'
  printf '════ end Sigmond panel ════  v3.69 · station AC1SN ════\n'
} > "$TMP/motd"
[ -s "$TMP/scrub.sh" ] && ( . "$TMP/scrub.sh"; _scrub_panel_file "$TMP/motd" )
nuls=$(tr -cd '\000' < "$TMP/motd" | wc -c | tr -d ' ')
[ "$nuls" = 0 ] && ok "all 2004 NUL bytes removed" || bad "$nuls NUL bytes left" "pam_motd stops at the first one"
! grep -q 'Wizard: sigmond-setup' "$TMP/motd" && ! grep -q '^  ==== Sigmond appliance' "$TMP/motd" \
    && ok "the old install banner is gone" || bad "the old banner survived" "$(grep -n 'Sigmond appliance v3.69 ====\|Wizard' "$TMP/motd")"
grep -q '^The programs included with the Debian' "$TMP/motd" && grep -q '^════ Sigmond appliance v3.69 — station AC1SN' "$TMP/motd" \
    && grep -q '^════ end Sigmond panel' "$TMP/motd" \
    && ok "the Debian notice and the panel itself are untouched" || bad "the scrub removed text it does not own" "$(cat -v "$TMP/motd")"

echo "── firstboot no longer writes the banner ───────────────────────"
grep -qE 'cat >> /etc/motd|^  Decoder VM: .*Wizard: sigmond-setup$' "$TMP/fb.code" \
    && bad "firstboot still appends the install banner to /etc/motd" "it duplicates the panel header" \
    || ok "no install banner in firstboot"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
