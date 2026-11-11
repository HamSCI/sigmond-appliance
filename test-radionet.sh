#!/bin/bash
# test-radionet.sh — the site radio network keeps radiod multicast off the LAN
# and still delivers any stream a VM on another host asks for.
#
# ⛔ WHY THIS EXISTS.  Most sites have an unmanaged switch and a Wi-Fi AP on
# the station LAN.  The switch floods multicast like broadcast, and the AP
# repeats it to every Wi-Fi client, so radiod streams (tens to hundreds of
# Mb/s) can make the LAN unusable.  sigmond-radionet carries them between the
# hosts in a VXLAN tunnel (unicast on the LAN) and IGMP snooping lets a stream
# into the tunnel only while someone across it has joined.  Two settings make
# or break that, and both broke once in the field:
#   - the tunnel port must NOT be a multicast router port, or every local
#     stream is copied to every peer (KFS 2026-11-09: 180 Mb/s from one host);
#   - with flooding into the tunnel off, link-local multicast (224.0.0.0/24:
#     IGMPv3 reports on .22, mDNS on .251) must still be copied in from the
#     local VMs, or a VM can neither join nor resolve a radiod on another host
#     (KPH 2026-11-09: `control` on KPH1 could not resolve KPH2, 0 packets).
#
#   usage: ./test-radionet.sh [path/to/firstboot-v3.sh]
set -u
SRC="${1:-$(dirname "$0")/firstboot-v3.sh}"
[ -f "$SRC" ] || { echo "FATAL: no firstboot-v3.sh at $SRC"; exit 1; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
chk(){ # chk <desc> <got> <want>
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf '  ok    %s\n' "$1"
    else FAIL=$((FAIL+1)); printf '  FAIL  %s\n        want: %s\n        got : %s\n' "$1" "$3" "$2"; fi; }
has(){ grep -qE -- "$2" "$1" && echo yes || echo no; }

# ── extract the script exactly as firstboot writes it ───────────────────────
awk "/^cat > \/usr\/local\/sbin\/sigmond-radionet <<'RADIONETEOF'\$/,/^RADIONETEOF\$/" "$SRC" \
    | sed '1d;$d' > "$WORK/sigmond-radionet"
[ -s "$WORK/sigmond-radionet" ] || { echo "FATAL: could not extract sigmond-radionet from $SRC"; exit 1; }
bash -n "$WORK/sigmond-radionet" || { echo "FATAL: extracted script does not parse"; exit 1; }
S="$WORK/sigmond-radionet"

echo "snooping inside the tunnel"
chk "snooping on"                 "$(has "$S" 'echo 1 > .*/bridge/multicast_snooping')" yes
chk "bridge is the querier"       "$(has "$S" 'echo 1 > .*/bridge/multicast_querier')" yes
chk "IGMPv3"                      "$(has "$S" 'echo 3 > .*/bridge/multicast_igmp_version')" yes
chk "tunnel never a router port"  "$(has "$S" 'bridge link set dev "\$VX" mcast_router 0 mcast_flood off')" yes

echo "joins and names still cross"
chk "copy hook on local VM ports" "$(has "$S" 'type filter hook ingress devices = \{ \$list \}')" yes
chk "copies all of 224.0.0.0/24"  "$(has "$S" 'ip daddr 224\.0\.0\.0/24 counter dup to "\$VX"')" yes
chk "never copies data groups"    "$(grep -E 'dup to' "$S" | grep -vc '224\.0\.0\.0/24')" 0
chk "tunnel port excluded"        "$(has "$S" 'grep -vx "\$VX"')" yes
chk "rule reinstalled every run"  "$(grep -c '^delete table netdev radionet$' "$S")" 1

echo "units"
chk "timer enabled by firstboot"  "$(has "$SRC" '^systemctl enable sigmond-radionet.timer')" yes
chk "runs every 2 minutes"        "$(awk "/^cat > \/etc\/systemd\/system\/sigmond-radionet.timer/,/^RNTMREOF\$/" "$SRC" | grep -c '^OnUnitActiveSec=2min')" 1

echo "inert, and silent, without a site config"
# The timer runs every 2 minutes (720 runs a day); with no radionet.conf a run
# prints nothing at all unless it has something left over to remove.
mkstubs(){ # mkstubs <dir> : ip/nft/bridge/qm that log their calls to <dir>/calls
    local d=$1; mkdir -p "$d"; : > "$d/calls"
    cat > "$d/ip" <<EOF
#!/bin/bash
echo "ip \$*" >> "$d/calls"
case "\$*" in
  "link show vxradio") [ -e "$d/vx-exists" ] ;;
  "-d -j link show vxradio") [ -e "$d/vx.json" ] && cat "$d/vx.json" ;;
  *) exit 0 ;;
esac
EOF
    cat > "$d/nft" <<EOF
#!/bin/bash
echo "nft \$*" >> "$d/calls"
[ "\$*" = "-f -" ] && cat >> "$d/nft-in"
case "\$*" in
  "list table "*) [ -e "$d/tables" ] ;;
  "-f -") [ ! -e "$d/nft-fails" ] ;;
  *) exit 0 ;;
esac
EOF
    printf '#!/bin/bash\necho "bridge $*" >> "%s/calls"\n' "$d" > "$d/bridge"
    printf '#!/bin/bash\necho "qm $*" >> "%s/calls"\n' "$d" > "$d/qm"
    chmod +x "$d"/ip "$d"/nft "$d"/bridge "$d"/qm; }
if [ ! -e /etc/sigmond/radionet.conf ]; then
    mkstubs "$WORK/u1"
    out=$(PATH="$WORK/u1:$PATH" bash "$S" 2>&1); rc=$?
    chk "exit 0 with no radionet.conf"     "$rc" 0
    chk "prints nothing with nothing to do" "$out" ""
    chk "creates no tunnel"                "$(grep -c 'link add' "$WORK/u1/calls")" 0
    mkstubs "$WORK/u2"; touch "$WORK/u2/vx-exists" "$WORK/u2/tables"
    out=$(PATH="$WORK/u2:$PATH" bash "$S" 2>&1); rc=$?
    chk "leftovers: exit 0"                "$rc" 0
    chk "leftovers: tunnel removed"        "$(grep -cx 'ip link del vxradio' "$WORK/u2/calls")" 1
    chk "leftovers: peer filter removed"   "$(grep -cx 'nft delete table inet sigmond_radionet' "$WORK/u2/calls")" 1
    chk "leftovers: says what it removed"  "$(echo "$out" | grep -c 'removed')" 3
else
    echo "  skip  /etc/sigmond/radionet.conf exists here (a live host); not running the script"
fi

# ── the pure functions, run on their own ────────────────────────────────────
sed -n '/^# ---- radionet functions/,/^# ---- end radionet functions/p' "$S" > "$WORK/fns"
[ -s "$WORK/fns" ] || { echo "FATAL: no radionet functions block"; exit 1; }
fn(){ ( NFT_TABLE="inet sigmond_radionet"; . "$WORK/fns"; "$@" ); }

echo "only the peers may send into the tunnel"
r=$(fn radionet_nft_rules 4789 10.2.80.20 10.2.80.11)
chk "own table, replaced atomically"   "$(echo "$r" | head -3 | tr '\n' '|')" "table inet sigmond_radionet|delete table inet sigmond_radionet|table inet sigmond_radionet {|"
chk "touches no other table"           "$(echo "$r" | grep -E '^(table|delete table)' | grep -vc 'inet sigmond_radionet')" 0
chk "accepts the IPv4 peers"           "$(echo "$r" | grep -c '^    ip saddr { 10.2.80.20, 10.2.80.11 } udp dport 4789 accept$')" 1
chk "drops every other source"         "$(echo "$r" | grep -c '^    udp dport 4789 counter drop$')" 1
chk "accept comes before drop"         "$(echo "$r" | grep -nE 'accept$|drop$' | cut -d: -f2 | grep -oE 'accept|drop' | tr '\n' ' ')" "accept drop "
chk "input hook, accept policy"        "$(echo "$r" | grep -c 'type filter hook input priority -10; policy accept;')" 1
r=$(fn radionet_nft_rules 4789 fd00::1 10.0.0.2)
chk "IPv6 peers go in ip6 saddr"       "$(echo "$r" | grep -c '^    ip6 saddr { fd00::1 } udp dport 4789 accept$')" 1
r=$(fn radionet_nft_rules 4789)
chk "no peers: drop only"              "$(echo "$r" | grep -cE 'accept$|saddr')" 0
chk "filter before the tunnel"         "$(grep -nE 'radionet_nft_rules "\$VXPORT"|ip link add "\$VX"' "$S" | cut -d: -f1 | tr '\n' ' ' | awk '{print ($1<$2)?"yes":"no"}')" yes
chk "no filter, no tunnel"             "$(grep -A3 'radionet_nft_rules "\$VXPORT"' "$S" | grep -c 'ip link del "\$VX"')" 1

echo "existing tunnel judged by its fields, not its text"
j(){ printf '[{"ifname":"vxradio","linkinfo":{"info_kind":"%s","info_data":{%s}}}]' "$1" "$2"; }
vx(){ fn radionet_vx_ok 4159 4789 vmbr0 && echo ok || echo rebuild; }
chk "matching tunnel kept"             "$(j vxlan '"id":4159,"port":4789,"link":"vmbr0","ttl":0' | vx)" ok
chk "extra fields don't matter"        "$(j vxlan '"port_range":{"low":0,"high":0},"link":"vmbr0","id":4159,"learning":true,"port":4789' | vx)" ok
chk "wrong VNI rebuilt"                "$(j vxlan '"id":4158,"port":4789,"link":"vmbr0"' | vx)" rebuild
chk "wrong dstport rebuilt"            "$(j vxlan '"id":4159,"port":8472,"link":"vmbr0"' | vx)" rebuild
chk "wrong uplink rebuilt"             "$(j vxlan '"id":4159,"port":4789,"link":"vmbr1"' | vx)" rebuild
chk "pinned local rebuilt"             "$(j vxlan '"id":4159,"port":4789,"link":"vmbr0","local":"10.2.80.5"' | vx)" rebuild
chk "not a vxlan rebuilt"              "$(j dummy '"id":4159' | vx)" rebuild
chk "no such link rebuilt"             "$(printf '' | vx)" rebuild

echo "the tunnel's family matches the peers'"
ja(){ printf '[{"ifname":"vxradio","ifalias":"%s","linkinfo":{"info_kind":"vxlan","info_data":{"id":4159,"port":4789,"link":"vmbr0"}}}]' "$1"; }
vx6(){ fn radionet_vx_ok 4159 4789 vmbr0 inet6 && echo ok || echo rebuild; }
chk "IPv6 tunnel kept for IPv6 peers"  "$(ja 'sigmond-radionet inet6' | vx6)" ok
chk "old alias-less tunnel rebuilt for IPv6 peers" "$(j vxlan '"id":4159,"port":4789,"link":"vmbr0"' | vx6)" rebuild
chk "IPv4 tunnel rebuilt for IPv6 peers" "$(ja 'sigmond-radionet inet' | vx6)" rebuild
chk "IPv6 tunnel rebuilt for IPv4 peers" "$(ja 'sigmond-radionet inet6' | vx)" rebuild
chk "alias-less IPv4 tunnel kept (KFS, KPH)" "$(j vxlan '"id":4159,"port":4789,"link":"vmbr0"' | vx)" ok
chk "IPv6 peers: tunnel made with local ::" "$(grep -c '_fam_arg="local ::"' "$S")" 1
chk "family written to the alias"      "$(grep -c 'ip link set "\$VX" alias "sigmond-radionet \$FAM"' "$S")" 1

echo "end to end with stubs (configured)"
sed -e "s|^CONF=.*|CONF=$WORK/radionet.conf|" -e "s|/sys/class/net/|$WORK/sys/|g" \
    -e "s|^nicstate=.*|nicstate=$WORK/nicstate|" -e "s|^state=/run/.*|state=$WORK/igmpstate|" "$S" > "$WORK/rn-conf"
mkdir -p "$WORK/sys/vmbr9/bridge" "$WORK/qemu"
printf 'RADIONET_PEERS="10.2.80.20 10.2.80.11"\n' > "$WORK/radionet.conf"
run(){ PATH="$WORK/$1:$PATH" RADIONET_QEMU_CONF_DIR="$WORK/qemu" bash "$WORK/rn-conf" 2>&1; }
mkstubs "$WORK/c1"; j vxlan '"id":4159,"port":4789,"link":"vmbr0"' > "$WORK/c1/vx.json"
out=$(run c1); rc=$?
chk "correct tunnel: exit 0"           "$rc" 0
chk "correct tunnel: not recreated"    "$(grep -c 'link add' "$WORK/c1/calls")" 0
chk "filter loaded with the peers"     "$(grep -c 'ip saddr { 10.2.80.20, 10.2.80.11 } udp dport 4789 accept' "$WORK/c1/nft-in")" 1
mkstubs "$WORK/c2"; j vxlan '"id":1,"port":4789,"link":"vmbr0"' > "$WORK/c2/vx.json"
out=$(run c2)
chk "wrong tunnel: recreated"          "$(grep -c 'ip link add vxradio mtu 1450 type vxlan id 4159 dstport 4789 dev vmbr0' "$WORK/c2/calls")" 1
mkstubs "$WORK/c3"; touch "$WORK/c3/nft-fails"
out=$(run c3); rc=$?
chk "filter fails: exit 1"             "$rc" 1
chk "filter fails: no tunnel built"    "$(grep -c 'link add' "$WORK/c3/calls")" 0

echo "VM NICs inherit the bridge MTU"
cat > "$WORK/qemu/100.conf" <<'EOF'
net0: virtio=BC:24:11:00:00:01,bridge=vmbr1
net1: virtio=BC:24:11:00:00:02,bridge=vmbr9
[snap1]
net1: virtio=BC:24:11:00:00:02,bridge=vmbr9,mtu=1
EOF
cat > "$WORK/qemu/101.conf" <<'EOF'
net1: virtio=BC:24:11:00:00:03,bridge=vmbr9,firewall=0
[PENDING]
net1: virtio=BC:24:11:00:00:03,bridge=vmbr9,firewall=0,mtu=1
EOF
printf 'net1: virtio=BC:24:11:00:00:04,bridge=vmbr9,mtu=1500\n'      > "$WORK/qemu/102.conf"
printf 'net1: virtio=BC:24:11:00:00:05,bridge=vmbr9,mtu=1450\n'      > "$WORK/qemu/103.conf"
printf 'net1: e1000=BC:24:11:00:00:06,bridge=vmbr9\n'                 > "$WORK/qemu/104.conf"
r=$(fn radionet_nic_fixes "$WORK/qemu" vmbr9 1450 | sort)
chk "fix list"                         "$(echo "$r" | tr '\n' '|')" "fix 100 net1 virtio=BC:24:11:00:00:02,bridge=vmbr9,mtu=1|fix 102 net1 virtio=BC:24:11:00:00:04,bridge=vmbr9,mtu=1|warn 104 net1 e1000|"
mkstubs "$WORK/c4"; j vxlan '"id":4159,"port":4789,"link":"vmbr0"' > "$WORK/c4/vx.json"
out=$(run c4)
chk "qm set issued for 100"            "$(grep -cx 'qm set 100 --net1 virtio=BC:24:11:00:00:02,bridge=vmbr9,mtu=1' "$WORK/c4/calls")" 1
chk "e1000 warned"                     "$(echo "$out" | grep -c 'VM 104 net1 .*cannot inherit')" 1
out=$(run c4)
chk "logged once, not every run"       "$(echo "$out" | grep -c 'VM 10')" 0

echo; echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
