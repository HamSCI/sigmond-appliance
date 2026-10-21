#!/bin/bash
# test-accept-ra.sh — a forwarding host must keep accepting router
# advertisements across a reboot.
#
# AI6VN, v3.75, 2026-10-21.  A Proxmox host forwards (it routes for the
# decoder VM), and Linux ignores RAs on a forwarding interface unless
# accept_ra is 2.  We set that at runtime in netfix and in the inet6 stanza's
# post-up, and neither survives: net.ipv6.conf.default.accept_ra is 1, so
# vmbr0 inherits 1 the moment networking.service creates it.
#
# The station then drops every RA.  With a 30 s router lifetime the IPv6
# default route expires almost at once, the RA's RDNSS is never consumed,
# resolv.conf keeps naming 127.0.0.1 where nothing listens, and frpc fails
# with "lookup vpn.hamsci.org on 127.0.0.1:53: server misbehaving".  The
# station is healthy on its own console and unreachable from outside.
#
# ⚠ The fix must set the DEFAULT, in /etc/sysctl.d.  A per-interface line
# there is applied by systemd-sysctl before network-pre.target, when vmbr0
# does not exist, and is silently lost -- the opposite of the rule that holds
# for every other interface sysctl in this file.
set -u
cd "$(dirname "$(readlink -f "$0")")"
FB="${1:-firstboot-v3.sh}"
[ -f "$FB" ] || { echo "FATAL: no firstboot-v3.sh at $FB"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

code=$(grep -vE '^[[:space:]]*#' "$FB")

echo "── the setting is made persistent at all ─────────────────────────"
conf=$(printf '%s\n' "$code" | grep -c 'sysctl.d/99-sigmond-ipv6-ra.conf')
[ "$conf" -ge 1 ] \
    && ok "firstboot writes /etc/sysctl.d/99-sigmond-ipv6-ra.conf" \
    || bad "nothing makes accept_ra survive a reboot" \
           "runtime sysctl and the stanza post-up both die with the interface"

echo "── it sets the DEFAULT, which is what a new interface inherits ───"
printf '%s\n' "$code" | grep -q 'net.ipv6.conf.default.accept_ra *= *2' \
    && ok "net.ipv6.conf.default.accept_ra = 2" \
    || bad "the default is not set to 2" \
           "vmbr0 inherits default.accept_ra when networking.service creates it"

echo "── and does NOT rely on a per-interface line in sysctl.d ─────────"
# A vmbr0-specific line in /etc/sysctl.d is applied before the interface
# exists, so a fix written that way looks right and does nothing.
blk=$(printf '%s\n' "$code" | sed -n '/99-sigmond-ipv6-ra.conf/,/^RACONF$/p')
if [ -n "$blk" ]; then
    if printf '%s\n' "$blk" | grep -qE 'net\.ipv6\.conf\.(vmbr0|enp|wlp)[^.]*\.accept_ra'; then
        bad "the drop-in names a specific interface" \
            "systemd-sysctl runs before network-pre.target; that line is lost"
    else
        ok "the drop-in names no specific interface"
    fi
else
    bad "could not isolate the sysctl.d block" "the fix was restructured"
fi

echo "── it is applied now, not only at the next boot ──────────────────"
printf '%s\n' "$code" | grep -A12 '99-sigmond-ipv6-ra.conf' | grep -q 'sysctl -q --system\|sysctl --system' \
    && ok "sysctl --system runs after writing it" \
    || bad "the drop-in is written but never applied" \
           "the first boot keeps dropping RAs until something reboots"

echo "── the runtime setters are still there as belt and braces ────────"
printf '%s\n' "$code" | grep -q 'net.ipv6.conf.vmbr0.accept_ra=2' \
    && ok "netfix/stanza still set it directly too" \
    || bad "the runtime setter was removed" \
           "the persistent default only helps interfaces created after it"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
