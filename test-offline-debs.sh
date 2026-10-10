#!/bin/bash
# test-offline-debs.sh -- firstboot's offline-debs branch, cut out of
# firstboot-v3.sh and run against stand-in dpkg tools.  No VM, no root.
#
# The branch applies every .deb of the stick, then asks dpkg which packages
# stayed "unpacked".  An unpacked wpasupplicant is harmful: it leaves ifupdown
# hooks whose targets are still .dpkg-new, and ifupdown2 then fails every
# interface bring-up.  The branch used to remove those four hooks whenever ANY
# package stayed unpacked.  With sudo among the packages, a missing dependency
# of sudo would then take a Wi-Fi-only station's hooks away, though its
# wpasupplicant stands configured.  The hooks go only with wpasupplicant itself.
#
# The block is cut from the first line that tests /mnt/sig-media/offline-debs
# to the first `fi` at the start of a line.  Only the two paths it writes
# under are rewritten, to a scratch directory; nothing else changes.
#
#   usage: ./test-offline-debs.sh [path/to/firstboot-v3.sh]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/firstboot-v3.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){  printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

awk '/^if \[ -d \/mnt\/sig-media\/offline-debs \]/{f=1} f{print} f && /^fi$/{exit}' "$SRC" \
    | sed "s#/mnt/sig-media#$T/media#g; s#/etc/network#$T/etc/network#g" > "$T/block.sh"
[ -s "$T/block.sh" ] || { echo "FAIL: no offline-debs branch found in $SRC"; exit 1; }
bash -n "$T/block.sh" || { echo "FAIL: the offline-debs branch does not parse"; exit 1; }

# Stand-in tools.  dpkg does nothing; dpkg-query prints $T/dpkg-state;
# every expected binary exists unless a scene lists it in $T/absent.
mkdir -p "$T/bin"
for t in awk tr ls wc cp mkdir rm cat sed; do ln -s "$(command -v $t)" "$T/bin/$t"; done
printf '#!/bin/sh\nexit 0\n' > "$T/bin/dpkg"
printf '#!/bin/sh\ncat "%s/dpkg-state"\n' "$T" > "$T/bin/dpkg-query"
chmod +x "$T/bin/dpkg" "$T/bin/dpkg-query"

# scene <name> <unpacked packages, space separated> <binaries to leave out>
# Leaves the block's `say` lines in $T/say and the hooks it kept in $T/hooks.
scene(){
    local unpacked="$2" absent="$3" b p
    rm -rf "$T/media" "$T/app" "$T/etc" "$T/say" "$T/bin/"{clatd,tayga,dnsmasq,rdisc6,wpa_supplicant,iw,btop,tmux,sudo}
    mkdir -p "$T/media/offline-debs" "$T/app"
    : > "$T/media/offline-debs/a.deb"; : > "$T/media/offline-debs/b.deb"
    for d in if-pre-up.d if-up.d if-down.d if-post-down.d; do
        mkdir -p "$T/etc/network/$d"; : > "$T/etc/network/$d/wpasupplicant"
    done
    : > "$T/dpkg-state"
    for p in clatd tayga dnsmasq wpasupplicant iw btop tmux sudo $unpacked; do
        case " $unpacked " in *" $p "*) echo "$p install ok unpacked" ;; *) echo "$p install ok installed" ;; esac
    done | sort -u >> "$T/dpkg-state"
    for b in clatd tayga dnsmasq rdisc6 wpa_supplicant iw btop tmux sudo; do
        case " $absent " in *" $b "*) ;; *) printf '#!/bin/sh\n' > "$T/bin/$b"; chmod +x "$T/bin/$b" ;; esac
    done
    ( PATH="$T/bin"; APP="$T/app"; LOG="$T/log"; say(){ printf '%s\n' "$*" >> "$T/say"; }
      . "$T/block.sh" ) >/dev/null 2>&1
    find "$T/etc/network" -name wpasupplicant 2>/dev/null | wc -l > "$T/hooks"
}
said(){ grep -qF -- "$1" "$T/say"; }
hooks(){ tr -d ' ' < "$T/hooks"; }

echo "a clean payload"
scene clean "" ""
[ "$(hooks)" = 4 ] && ok "the four hooks stay" || bad "the hooks changed on a clean payload ($(hooks) left)"
said "applied and configured" && ok "the success line prints" || bad "no success line"
said "sudo all present" && ok "the success line names sudo" || bad "the success line does not name sudo"
said "LEFT UNCONFIGURED" && bad "a clean payload reports unconfigured packages" || ok "no unconfigured packages reported"

echo "sudo stays unpacked (a dependency of sudo is missing)"
scene sudo-unpacked "sudo" ""
[ "$(hooks)" = 4 ] && ok "wpasupplicant's four hooks STAY" || bad "sudo unpacked took the wpasupplicant hooks away ($(hooks) left of 4)"
said "LEFT UNCONFIGURED:sudo" && ok "the unconfigured package is named" || bad "sudo is not named as unconfigured"
said "removing" && bad "a line says hooks are removed, and none were" || ok "no line claims a removal"
said "applied and configured" && bad "the success line prints with an unpacked package" || ok "no success line"

echo "wpasupplicant stays unpacked"
scene wpa-unpacked "wpasupplicant" ""
[ "$(hooks)" = 0 ] && ok "the four hooks go" || bad "the hooks stand with wpasupplicant unpacked ($(hooks) left)"
said "LEFT UNCONFIGURED:wpasupplicant" && ok "the unconfigured package is named" || bad "wpasupplicant is not named as unconfigured"
said "removing" && ok "the removal is said" || bad "the removal is not said"

echo "wpasupplicant and sudo both unpacked"
scene both "sudo wpasupplicant" ""
[ "$(hooks)" = 0 ] && ok "the four hooks go" || bad "the hooks stand with wpasupplicant unpacked ($(hooks) left)"

echo "a package whose name only contains wpasupplicant"
scene lookalike "wpasupplicant-doc" ""
[ "$(hooks)" = 4 ] && ok "the hooks stay: the match is on the whole name" || bad "a lookalike name took the hooks away ($(hooks) left of 4)"

echo "sudo is configured but its binary is not on PATH"
scene no-sudo-bin "" "sudo"
said "missing binaries: sudo" && ok "the missing binary is named" || bad "a missing sudo binary is not reported"
said "applied and configured" && bad "the success line prints without sudo" || ok "no success line"

printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$pass" "$fail"
[ "$fail" = 0 ] && echo "PASS: offline-debs branch" || echo "FAILED: offline-debs branch"
exit "$fail"
