#!/bin/bash
# test-reflash-docs.sh -- the three install docs must carry the reflash
# section, with the same three smd verbs in the same order.
#
# v3.83 row 4: B4's 10-26 reflash had no key file on the stick; the keys went
# back by hand and nothing ran `smd psws verify`.  The section must say:
# save before the flash, restore if the stick missed it, verify at the end.
set -u
cd "$(dirname "$(readlink -f "$0")")"
pass=0; fail=0
ok(){  printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# section FILE ENDPATTERN: print from the heading line to the next heading.
section(){ awk -v end="$2" '
  tolower($0) ~ /reflashing or replacing a station/ {on=1; print; next}
  on && $0 ~ end {exit}
  on {print}' "$1"; }

check(){
  local f=$1 end=$2 s s1 s2 s3
  if [ ! -f "$f" ]; then bad "$f missing"; return; fi
  s=$(section "$f" "$end")
  if [ -z "$s" ]; then bad "$f: no 'Reflashing or replacing a station' section"; return; fi
  ok "$f: section present"
  for v in 'smd psws save-keys' 'smd psws restore-keys' 'smd psws verify'; do
    if grep -qF "$v" <<<"$s"; then ok "$f: $v"; else bad "$f: $v missing"; fi
  done
  s1=$(grep -nF 'smd psws save-keys' <<<"$s" | head -1 | cut -d: -f1)
  s2=$(grep -nF 'smd psws restore-keys' <<<"$s" | head -1 | cut -d: -f1)
  s3=$(grep -nF 'smd psws verify' <<<"$s" | tail -1 | cut -d: -f1)
  if [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$s3" ] && [ "$s1" -lt "$s2" ] && [ "$s2" -lt "$s3" ]; then
    ok "$f: save, then restore, then verify"
  else bad "$f: order is not save < restore < verify"; fi
  if grep -qF 'tar czf site-keys.tar.gz' <<<"$s"; then ok "$f: v3.82 tar fallback kept"
  else bad "$f: tar fallback missing"; fi
}

check INSTALL.md '^## '
check docs/install-page.html '<h2>'
check QUICKSTART.txt '^[0-9]+\. +[A-Z]'
if grep -rnE '§4|Returning station\?' INSTALL.md | grep -q 'Returning station'; then
  bad "INSTALL.md: stale heading text"; else ok "INSTALL.md: no stale heading text"; fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
