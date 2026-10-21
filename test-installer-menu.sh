#!/bin/bash
# test-installer-menu.sh — the stick must not erase a machine behind a
# ten-second countdown and a title that names a product, not an action.
#
# Chris, Jenny Jump, 2026-10-20 (v3.74 row 1): "the boot menu counts down a
# few seconds, then installs without asking, and the install erases the
# internal disk."  The stock entry really is `set timeout=10` under
# 'Install Proxmox VE (Automated)'.
#
# The patch rewrites /boot/grub/grub.cfg INSIDE the iso9660 and must be
# length-preserving: build-usb-v3.sh locates the ESP by sector and appends
# the payload at the iso9660 volsize offset, so an image whose length moves
# takes both with it.  These tests hold that line, and hold the call ahead of
# both readers in the build.
set -u
cd "$(dirname "$(readlink -f "$0")")"
PATCHER="${1:-patch-installer-menu.sh}"
BUILD="${2:-build-usb-v3.sh}"
[ -f "$PATCHER" ] || { echo "FATAL: no patcher at $PATCHER"; exit 1; }
pass=0; fail=0
ok(){  printf '  ✓ %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf '  ✗ %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# A faithful copy of the stock block, with enough of its surroundings that a
# patch which ran off the end would be visible.
stock(){ cat <<'CFGEOF'
insmod gzio
insmod iso9660
set gfxmode=1024x768,640x480

if [ -f auto-installer-mode.toml ]; then
    set timeout-style=menu
    set timeout=10

    menuentry 'Install Proxmox VE (Automated)' --class debian --class gnu-linux --class gnu --class os {
        echo        'Loading Proxmox VE Automatic Installer ...'
        linux       /boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer
        echo        'Loading initial ramdisk ...'
        initrd      /boot/initrd.img
     }
fi

menuentry 'Install Proxmox VE (Graphical)' --class debian --class gnu-linux --class gnu --class os {
    linux	/boot/linux26 ro ramdisk_size=16777216 rw quiet splash=silent
}
CFGEOF
}

echo "── the patch preserves the image's length exactly ────────────────"
stock > "$TMP/a.cfg"; b=$(stat -c%s "$TMP/a.cfg")
if out=$(bash "$PATCHER" "$TMP/a.cfg" 60 2>&1); then
    a=$(stat -c%s "$TMP/a.cfg")
    [ "$b" = "$a" ] && ok "length unchanged ($b bytes) after patching" \
        || bad "the image's length moved $b -> $a" \
               "the ESP sector lookup and the payload offset both shift with it"
else
    bad "the patcher failed on the stock menu block" "$out"
fi

echo "── it lengthens the countdown and names the action ───────────────"
grep -q 'set timeout=60' "$TMP/a.cfg" \
    && ok "countdown is 60 s" \
    || bad "the countdown is not 60 s" "ten seconds is what Chris reported"
grep -q 'set timeout=10' "$TMP/a.cfg" \
    && bad "the old 10 s timeout is still present" "the patch did not take" \
    || ok "the 10 s timeout is gone"
grep -q "ERASES THE INTERNAL DISK" "$TMP/a.cfg" \
    && ok "the menu entry says ERASES THE INTERNAL DISK" \
    || bad "the menu entry does not say what it erases" \
           "'Install Proxmox VE (Automated)' names a product, not an action"

echo "── the entry still performs an unattended install ────────────────"
grep -q 'proxmox-start-auto-installer' "$TMP/a.cfg" \
    && ok "the auto-installer kernel argument survives" \
    || bad "proxmox-start-auto-installer was lost" "unattended installs would break"
if [ "$(grep -c 'menuentry ' "$TMP/a.cfg")" = "$(stock | grep -c 'menuentry ')" ]; then
    ok "the menu still has every entry it started with"
else
    bad "the number of menu entries changed" "the patch ate or added an entry"
fi
awk '{o+=gsub(/{/,"{"); c+=gsub(/}/,"}")} END{exit !(o==c)}' "$TMP/a.cfg" \
    && ok "braces still balance" \
    || bad "the braces no longer balance" "grub would refuse the config"

echo "── a second run is a no-op, not a second patch ───────────────────"
s1=$(stat -c%s "$TMP/a.cfg"); m1=$(md5sum < "$TMP/a.cfg")
# ⛔ The exit status matters as much as the bytes.  build-usb-v3.sh runs the
# patcher under `|| exit 1`, so a patcher that merely DECLINES the second run
# -- "stock block not found" -- kills every re-run of the build on an ISO
# that is already prepared.  Unchanged bytes alone cannot tell the two apart.
if bash "$PATCHER" "$TMP/a.cfg" 60 >/dev/null 2>&1; then
    rc_ok=yes
else
    rc_ok=no
fi
s2=$(stat -c%s "$TMP/a.cfg"); m2=$(md5sum < "$TMP/a.cfg")
[ "$s1 $m1" = "$s2 $m2" ] && ok "re-running changes nothing" \
    || bad "a second run altered the file" "a re-run of the build would corrupt the ISO"
[ "$rc_ok" = yes ] && ok "a second run exits 0, so the build survives a re-run" \
    || bad "the patcher exits non-zero on an already-patched image" \
           "build-usb-v3.sh runs it under || exit 1 — every re-build would die"

echo "── it refuses what it does not recognise ─────────────────────────"
printf 'insmod gzio\nmenuentry %s {\n}\n' "'Something Else'" > "$TMP/b.cfg"
if bash "$PATCHER" "$TMP/b.cfg" 60 >/dev/null 2>&1; then
    bad "the patcher reported success on an ISO without the stock block" \
        "a Proxmox ISO that changed its grub.cfg would ship unpatched and silent"
else
    ok "an unrecognised grub.cfg is a hard failure, not a silent pass"
fi
{ stock; stock; } > "$TMP/c.cfg"
if bash "$PATCHER" "$TMP/c.cfg" 60 >/dev/null 2>&1; then
    bad "the patcher guessed when the block appeared twice" "it must refuse"
else
    ok "two candidate blocks is a refusal, not a guess"
fi

echo "── the build calls it, and calls it early enough ─────────────────"
if [ -f "$BUILD" ]; then
    code=$(grep -vE '^[[:space:]]*#' "$BUILD")
    call=$(printf '%s\n' "$code" | grep -n 'patch-installer-menu.sh' | head -1 | cut -d: -f1)
    esp=$(printf  '%s\n' "$code" | grep -n 'ESP_START=' | head -1 | cut -d: -f1)
    vol=$(printf  '%s\n' "$code" | grep -n 'od -An -tu4' | head -1 | cut -d: -f1)
    prep=$(printf '%s\n' "$code" | grep -n 'prepare-iso' | head -1 | cut -d: -f1)
    if [ -n "$call" ]; then
        ok "build-usb-v3.sh runs the patcher (line $call)"
        [ -n "$prep" ] && [ "$prep" -lt "$call" ] \
            && ok "it runs after prepare-iso (line $prep), so the file exists" \
            || bad "the patcher runs before prepare-iso" "there is no ISO to patch yet"
        [ -n "$esp" ] && [ "$call" -lt "$esp" ] \
            && ok "it runs before the ESP is located by sector (line $esp)" \
            || bad "the patcher runs after ESP_START is read" "the ESP would be cut from stale sectors"
        [ -n "$vol" ] && [ "$call" -lt "$vol" ] \
            && ok "it runs before the volsize/payload offset is read (line $vol)" \
            || bad "the patcher runs after the payload offset is computed" "the payload would land wrong"
        printf '%s\n' "$code" | grep -A3 'patch-installer-menu.sh' | grep -q 'FATAL\|exit 1' \
            && ok "a failed patch stops the build" \
            || bad "the build ignores a failed patch" \
                   "a stick would ship with the ten-second countdown and nobody would know"
    else
        bad "build-usb-v3.sh never calls patch-installer-menu.sh" "row 1 is not wired in"
    fi
else
    bad "no build-usb-v3.sh at $BUILD" "cannot check the wiring"
fi

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
