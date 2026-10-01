# vm-console — the decoder-VM half of the split console

These files install **inside the decoder VM**, not on the Proxmox host, which
is why `firstboot-v3.sh` does not write them. The host half
(`sigmond-console-relay` / `sigmond-console-paint`) ships in the image; this
half is applied to the VM.

## The problem it solves

A Sigmond station's Proxmox host has **no keyboard and no USB at all**. Both
USB controllers are bound to `vfio-pci` for the decoder VM, so `lsusb` on the
host returns nothing. The operator standing in front of the machine can
neither type a command nor plug in a recovery stick.

The two halves of a usable console are on different machines:

    keystrokes  ->  the decoder VM   (the USB keyboard enumerates there)
    pixels      ->  the Proxmox host (VT1, where the access panel paints)

Neither is usable alone. The bridge joins them over the private
`10.99.0.0/30` host-only link — which has no physical port and is therefore up
whether or not the station has any uplink. That is exactly the situation this
exists for: the network is broken and there is no other way in.

## ⛔ ssh will not read the password from stdin

`ssh` opens `/dev/tty` for both the password prompt and the answer. Here that
fails twice over: the prompt goes to the VM's invisible screen instead of the
operator's monitor, and the read lands nowhere at all.

Measured on AI6VN-PM, 2026-10-01 03:53:58 — two failures inside **one second**
with a human present who had typed nothing:

    03:53:58  Failed password for root from 10.99.0.2
    03:53:58  Failed password for root from 10.99.0.2

That signature — several failures in the same second — means an empty read,
not a wrong password. A wrong password produces one failure per attempt,
spaced by however long the human took to type.

`SSH_ASKPASS_REQUIRE=force` stops ssh touching `/dev/tty`:
`sigmond-console-askpass` reads the keyboard device explicitly with echo off,
and the bridge prints the prompt through the relay where it can be seen. The
prompt **must** say that typing will not echo, or the operator reads a silent
screen as a hung one.

Confirmed working 2026-10-01 04:00:53: `Accepted password for root from
10.99.0.2`.

## What it carries

**Output and keystrokes, never authority.** The VM could already reach the
host over the `/30`; what it could not do was show the result to the person at
the screen. The operator still authenticates with the host's own credentials.
This is not a new privilege path and must not become one — in particular, do
not "simplify" it by installing a VM→host ssh key, which would turn a
compromise of the network-facing decoder VM into host root.

The host-side relay binds `10.99.0.1` only, never `0.0.0.0`: it writes
straight to the physical console and must not be reachable from the site
network.

## Install

From inside the decoder VM:

    bash install-in-vm.sh

It verifies byte counts and syntax before touching anything, then replaces the
(invisible) `getty@tty1` with the bridge.

Undo:

    sudo rm -rf /etc/systemd/system/getty@tty1.service.d
    sudo systemctl daemon-reload && sudo systemctl restart getty@tty1

## Still to do

Productize into the VM image so a greenfield install has it without a manual
step — it belongs in the component that builds the decoder VM, alongside the
other VM-side units.
