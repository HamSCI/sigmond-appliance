#!/bin/bash
# patch-installer-menu.sh — lengthen the auto-installer countdown and say, in
# the menu entry itself, that the entry erases the machine's internal disk.
#
# Chris, Jenny Jump, 2026-10-20 (v3.74 row 1): "the boot menu counts down a
# few seconds, then installs without asking, and the install erases the
# internal disk."  It is literally a few: the stock entry reads
#
#     if [ -f auto-installer-mode.toml ]; then
#         set timeout-style=menu
#         set timeout=10
#         menuentry 'Install Proxmox VE (Automated)' ...
#
# -- ten seconds, and a title that names a product rather than an action.
# (The v3.74 list says 30 s; the ISO we ship says 10.)
#
# ⛔ THE PATCH IS LENGTH-PRESERVING, AND THAT IS THE WHOLE DESIGN.
# The menu lives at /boot/grub/grub.cfg INSIDE the iso9660, not in the ESP
# (the ESP holds a three-line stub that sources it).  build-usb-v3.sh appends
# the payload at the 1 MiB-aligned iso9660 volsize offset and the ESP is
# located by sector, so anything that changes the image's length or layout
# moves both.  Rewriting the same number of bytes over a file's extent
# touches no iso9660 metadata, no El Torito catalogue, no MBR, no GPT and no
# ESP -- the image is byte-identical everywhere else.  The script therefore
# balances every edit against savings in the same region and refuses to write
# if the length moved by even one byte.
#
# Usage: patch-installer-menu.sh <iso-or-fixture> [timeout-seconds]
set -euo pipefail
TARGET="${1:?usage: patch-installer-menu.sh <iso> [timeout]}"
TIMEOUT="${2:-60}"
[ -f "$TARGET" ] || { echo "FATAL: no such file: $TARGET" >&2; exit 1; }
case "$TIMEOUT" in ''|*[!0-9]*) echo "FATAL: timeout must be a number" >&2; exit 1 ;; esac

python3 -I - "$TARGET" "$TIMEOUT" <<'PYEOF'
import sys, pathlib

target, timeout = pathlib.Path(sys.argv[1]), sys.argv[2]
blob = target.read_bytes()
before = len(blob)

OLD = (b"if [ -f auto-installer-mode.toml ]; then\n"
       b"    set timeout-style=menu\n"
       b"    set timeout=10\n"
       b"\n"
       b"    menuentry 'Install Proxmox VE (Automated)'"
       b" --class debian --class gnu-linux --class gnu --class os {\n")

n = blob.count(OLD)
if n == 0:
    # Already patched is not an error: the build may re-run on a prepared ISO.
    if b"ERASES THE INTERNAL DISK" in blob:
        print("installer menu: already patched, leaving it alone"); sys.exit(0)
    print("FATAL: the stock auto-installer menu block was not found.\n"
          "       The Proxmox ISO changed its grub.cfg; re-read it and update OLD.",
          file=sys.stderr)
    sys.exit(1)
if n != 1:
    print("FATAL: the menu block appears %d times; refusing to guess" % n, file=sys.stderr)
    sys.exit(1)

TITLE = b"Install Sigmond: ERASES THE INTERNAL DISK"
# `--class debian` and `--class gnu` only pick a theme icon; spending them on
# words the operator reads is the better trade.
HEAD = (b"if [ -f auto-installer-mode.toml ]; then\n"
        b"    set timeout-style=menu\n"
        b"    set timeout=" + timeout.encode() + b"\n")
TAIL = (b"\n"
        b"    menuentry '" + TITLE + b"'"
        b" --class gnu-linux --class os {\n")
NEW_CORE = HEAD + TAIL

slack = len(OLD) - len(NEW_CORE)
if slack < 0:
    print("FATAL: the new menu block is %d bytes too long; shorten the title "
          "or free more --class decorations" % -slack, file=sys.stderr)
    sys.exit(1)

# Absorb the slack inside the region, as a grub comment line.  grub.cfg takes
# `#` comments anywhere a command may appear.
# Placed between the timeout and the menuentry, so the filler sits in the
# `if` body and never inside the menu entry's own block.
if slack == 0:
    pad = b""
elif slack == 1:
    pad = b"\n"                      # one more blank line
else:
    pad = b"#" + b" " * (slack - 2) + b"\n"
NEW = HEAD + pad + TAIL

assert len(NEW) == len(OLD), "padding arithmetic is wrong: %d vs %d" % (len(NEW), len(OLD))

blob = blob.replace(OLD, NEW, 1)
if len(blob) != before:
    print("FATAL: image length moved %d -> %d; refusing to write"
          % (before, len(blob)), file=sys.stderr)
    sys.exit(1)

target.write_bytes(blob)
print("installer menu: countdown %ss, entry reads %s"
      % (timeout, TITLE.decode()))
print("installer menu: %d bytes rewritten in place, image length unchanged (%d)"
      % (len(OLD), before))
PYEOF
