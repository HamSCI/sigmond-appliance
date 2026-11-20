# Release history kept from the old release process

These sections stayed behind when the process moved to sigmond. They record
what the rolled rung means, four withdrawn or hard-won builds, and three rules.

## What "rolled" now means: the station brings ITSELF up

Through v3.41 the install ended with a configured, reachable VM and **nothing
running** — no radiod instance, no ka9q-web, no recorders. Installing and
starting the station software was a separate operator step that nothing in
the install told anyone to run, so a finished install looked complete while
the station was dead. It was hit twice on AI6VN on 2026-09-17, the second
time on a clean v3.41 install whose ka9q-web page simply would not load.

From v3.42, `sigmond-firstrun-bringup.service` (in HamSCI/sigmond, installed
by its `install.sh`) runs the bring-up once, on the first boot after the
wizard personalizes the host — which is exactly the boot the finalizer
arranges when it powers the machine off so the operator powers it back on
with the RX-888 freshly reset. It is a no-op on an un-personalized host and
on every boot thereafter, and it writes its marker even when bring-up fails
so a station that cannot build does not retry forever.

Consequence for this document: an image is not "rolled" when it installs, it
is rolled when the station it installed is running. The nested test's Phase D
now exercises that path, so a regression in first-run bring-up shows up
before a release, not at a site.

### v3.54: an unattended install finally measures something

Nothing in THIS repo changed between v3.53 and v3.54. The whole difference
is in the golden VM, which clones `HamSCI/sigmond` at build time — so v3.54
is a deliberate rebuild of the decoder template, not a payload change, and
building it on the v3.53 template would have reproduced the defect below.

**The defect it closes.** `sigmond-site-timing` was run by the wizard
(~line 1083) BEFORE first-run bring-up started (~line 1158). Its step 3
needs `/etc/hf-timestd/` to exist, so on a fresh install it skipped,
silently, and nothing re-ran it. The result was a station with **no
metrology at all**: zero `timestd-metrology@` units, no
`/etc/hf-timestd/metrology-channels/`, fusion logging `0 entries from 6
channels`, no T3 — and every unit green.

B4 ran that way from its reflash until 2026-09-23. rob's lab station did the
same on v3.53 and needed the command run by hand. That is the part that
matters for this document: **an appliance needing a manual step after an
unattended install is not unattended**, and this step was invisible, because
the station looked healthy while measuring nothing.

`sigmond-firstrun-bringup` now re-runs the site wiring after `smd bringup`
returns, where hf-timestd and its config exist, and then COUNTS the channels
and logs the number. "Site wiring complete" with zero channels running is
the exact shape of the failure, and a log line that could not tell the two
apart is how it hid for a week.

**Also carried, from v3.51–v3.53:** the bring-up race (wizard and
`sigmond-firstrun-bringup.service` both running `smd bringup` with no mutual
exclusion — ten lost `smd install` steps on AI6VN); the panel's `cur_ip`/
`ipurl` helpers being defined in a different script; netfix reading a live
cable in vmbr0's own port as NO NETWORK CABLE DETECTED; and the port relay
paying the guest agent's ~3.8 s timeout on every single connection.

Evidence to look for after installing it, in the VM:

    grep -c "lifecycle lock held" /var/log/sigmond/firstrun-bringup.log   # 0
    systemctl list-units 'timestd-metrology@*' --no-legend | wc -l        # 6

### v3.44: WITHDRAWN — the build did not ship what the tag said

Do not bless or install v3.44. It was never blessed and the tag was never
pushed; the only copy is one lab stick.

`build-usb-v3.sh` `cd`s into the rig staging dir and read `firstboot-v3.sh`
from `$PWD`. Nothing syncs that directory from git, so v3.44 shipped a
firstboot **three days older than its own tag**, silently missing both
appliance commits the tag contained:

    grep -a -c "qm snapshot"    sigmond-appliance-v3.44-...img  -> 0
    grep -a -c "def local_nets" sigmond-appliance-v3.44-...img  -> 0

All seven bless gates passed, and were right to: every one reads the REPO —
tag reachable, tree clean, manifest present, test log — and none had ever
looked inside the artefact. A green ladder said nothing about what was on the
stick.

Blast radius is exactly one release. No commit touched `firstboot-v3.sh`
between `e930be9` (09-15) and the two on 09-19, so v3.40–v3.43 were built
from a stale copy that happened to be byte-identical to their tags. Nothing
in the field is affected.

Three fixes, all in v3.45:

- the build copies its own repo's files from the checkout and logs the sha it
  took them from
- the manifest records `firstboot_sha256`, and bless gate 5b recomputes it
  from `git show <tag>:firstboot-v3.sh` and refuses a mismatch. Proven in
  both directions before being trusted — the first version of that gate
  sampled lines that never change between releases and passed on the
  known-bad image, which is worse than no gate because it reads as assurance
- a new non-blocking `WARN` result, so an artefact that predates the hash
  reports "not verifiable" instead of PASS

### v3.45: the decoder VM lives behind the host

The VM used to take its own DHCP lease on `vmbr0`, making its address a
property of a network we do not control. Everything downstream had to cope:
the port relay guessed which address was reachable, the console panel
advertised one that might not be, and the lease moved underneath both.

Where a site puts the host and its own VM in different VLANs that is not
awkward but fatal. Scranton's DASI-019 answered ICMP in 8.9 ms — hairpinned
out through the NAT gateway and back — while refusing TCP 22 from the
hypervisor beside it, and every `vm-*` RAC channel was dead.

The VM now gets ONE link: a host-only `/30` at a fixed `10.99.0.2`, with the
host routing and NATing for it. Identical on a flat LAN and on a VLAN-split
campus.

Two things worth knowing when reading the code:

**The guest is configured over the guest agent, not the network.** There is
no DHCP on `vmbr1` by design, so the VM boots with no IPv4 and cannot be
reached to fix that — but virtio-serial does not care. That is what makes it
safe: a mistake in the config it delivers cannot lock anyone out, because the
channel is not the network it configures. The host then *verifies* it can
open TCP 22, because "configured" without checking is how the Scranton
channels read healthy while being dead.

**The VM's services stay on the LAN, at the host's address.** 8000
station-web, 8081 ka9q-web, 8082 gmag-webui, and 2222→22 for ssh (the host's
own sshd owns 22). Those four were measured on a running station, not
assumed; forwarding only ka9q-web would have quietly removed two web UIs.

Phase C of the nested test now asserts all of it — the snapshot, the single
NIC on `vmbr1`, the bridge, forwarding, NAT, all four ports, and reachability
last and separately. v3.44 is the argument for that: an untested feature in
an image is indistinguishable from a missing one, and the operator's only
signal was an absence.

### v3.43: the SDR gate has to run BEFORE radiod is configured

v3.42 shipped the first-run bring-up with its SDR gate in the wrong stage,
and rob's install proved it within the hour. `smd config init radiod` probes
the USB bus to DETECT the SDR — in stage 1 — and a miss there fails the hard
"radiod configured" checkpoint and aborts the whole bring-up. The gate sat in
stage 4, so it never ran at all:

    config init radiod: no recognised SDRs detected on the USB bus
    checkpoint: radiod configured FAILED — /etc/radio: 0 radiod conf(s)
    aborting (hard checkpoint)

The card was not even latched. An RX-888 enumerates first as its FX3
bootloader and only becomes 04b4:00f1 once firmware is loaded — and bring-up
installs that firmware and reloads udev earlier in the same run — so the card
appeared healthy on the bus about a minute after config init gave up on it. A
race, not a fault. Cutting VBUS at that moment would have thrown away a card
that was arriving.

v3.43 carries HamSCI/sigmond 0a835c7: the gate moves ahead of `configure
radiod`, and waits for a slow FX3 before resorting to a power cycle. The
lesson for this document: a nested test cannot prove hardware ordering,
because the nest has no card either way. Only a real install can.

## Three rules that have cost real time

**The manifest is generated, never hand-written.** `build-golden-vm.sh`
captures the component pin block (`smd version`, run from inside the golden
template — the only point in the pipeline where components are installed
*and* still reachable over ssh) into `manifest-raw.txt`; `build-usb-v3.sh`
stitches that together with the version/commit/checksum into the final
`.manifest.txt` it ships. A hand-typed pin drifts silently the moment
anyone forgets to update it after a component bump, and nothing downstream
would notice — the whole point of a manifest is that it is a *record*, not
an assertion. If `manifest-raw.txt` is missing, the build hard-refuses to
ship rather than let an unmanifested image out the door.

**The manifest also rides the payload, minus one field.** `build-usb-v3.sh`
writes a second copy of the same `manifest-raw.txt` snapshot — same
version/commit/tag/build time, same component rows — into the payload as
`manifest.txt`, and `firstboot-v3.sh` installs it to
`/etc/sigmond-appliance/manifest.txt` on every host built after this
shipped (Stage 3). That copy has no `image_sha256` line: the field is the
hash of the finished `.img`, which does not exist until after the payload
is already sealed inside it, so a self-referential checksum can't be
written into it. The file itself says so and points at the
Release-attached copy for the checksum. Everything else needed to answer
"am I what my image says I am" — the component pins in particular — is
identical between the two copies, because both come from the same
`manifest-raw.txt` read.

**Verify the venv, not the checkout.** A component can be "updated" in its
git checkout while the running process still imports from a stale venv —
this happened on B4, where a fix was "verified" live for a full day while
the venv it actually ran from had not moved. Checking `git log` or `git
status` in a checkout proves nothing about what code is loaded at runtime.
Check the venv's installed package (or its `pip show` / site-packages
mtime) directly.

**Verify `/proc/PID/exe`, not the file you installed.** A binary swap can
"succeed" — the new file lands at the expected path — while the running
process still holds the old inode open, or while a drop-in unit override
points `ExecStart` at a different binary than the one just replaced. This
is exactly how a radiod swap was once silently a no-op: the 11:02 attempt
installed the right file, but a stale `10-patched.conf` drop-in was still
launching a different executable, and nothing failed loudly. `readlink
/proc/<pid>/exe` (or equivalent) is the only check that reflects what is
actually executing, as opposed to what is sitting on disk at the path you
expect.
