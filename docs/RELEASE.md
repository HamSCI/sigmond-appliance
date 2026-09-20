# Release process

An appliance image moves through four rungs. "Verified" used to mean
different things depending on who said it and when — a fix once shipped
"verified" while the venv it ran from was stale, and a radiod binary swap
was "verified" against a file that was not the one actually running. Every
rung below has a concrete evidence requirement precisely so "verified" can
mean only one thing again: the evidence exists, in the expected shape, tied
to the exact artifact in question.

## The four rungs

### 1. Built

`build-usb-v3.sh` (tag-driven since Stage 2 — the version comes from the
git tag on `HEAD`, never a typed argument) produces, in the build rig
directory:

- the image: `sigmond-appliance-<version>-<stamp>.img`
- its checksum: `sigmond-appliance-<version>-<stamp>.sha256`
- its manifest: `sigmond-appliance-<version>-<stamp>.manifest.txt`

Evidence an image is "built": all three files exist, the tag the version
came from is a real annotated/lightweight tag on a clean `HEAD`, and the
image ships to the artifact store (wd30) immediately, before testing —
built is not the same claim as tested.

**Untested builds land in `wd30:~/pending/`, never the download
directory.** ⛔ They used to go straight to `wd30:~/`, where a
built-but-untested image sat beside blessed ones and could not be told
apart. The v3.36 build day shows what that costs.

On 2026-09-02 the builder produced an image at 18:22Z from a wizard
checkout 64 commits stale, and shipped it to the download directory two
minutes later. The nested test then stopped that image at 18:45Z on
`FATAL: location-check timer not enabled in VM` — the stale wizard never
enabled the timer. A second build followed at 18:50Z, carrying the
current wizard, and at 19:01Z it overwrote the first on wd30: image,
`.sha256` and manifest, all under the same filename. That second image
passed PHASE D at 19:44Z, and the v3.36 Release blesses it.

So the download directory held a failed image for 37 minutes, under the
very name that now denotes a blessed release. Two things make the window
worse than it sounds. Anyone who fetched the `.img` and the `.sha256`
together inside it holds a self-consistent pair that verifies clean —
the checksum confirms an honest download of the wrong build. And the
rebuild erased the evidence: a filename records the version, not the
checksum, so no host installed that day can now say which v3.36 it came
from. AC0G-ND, installed from v3.36, cannot answer that question.

Staging closes the window rather than narrowing it. A rebuild still
overwrites its predecessor, but it does so inside `pending/`, where
overwriting an untested build with another untested build costs nothing.

Parallel download stays: fetching from `pending/` is fine and useful, and
it is now an explicit act of taking an untested build. What changed is
that "in wd30's download directory" now *means* blessed, and step 3 is
the only thing that puts a file there.

### 2. Tested

`test-nested-v3.sh` drives the image through a four-phase nested boot
(auto-install → NVMe-only boot → USB-triggered import → wizard/finalizer/
production reboot), appending to `test-v3.log` as it goes. The log is
append-only across every build this rig has ever run.

Evidence an image is "tested": a `PHASE D PASS — NESTED TEST COMPLETE` line
that belongs to a block starting with `USB image under test: <this exact
filename>`, with no later re-run of the same filename that failed. A `PASS`
string that exists somewhere in the log is not evidence — it has to be
*this image's* most recent run. `bless-release.sh` gate 5 is what makes
this distinction mechanically, because a human skimming a growing log
cannot reliably make it by eye.

Since v3.33, Phase D also asserts the fleet-awareness payload rides the
image — and asserts it *correctly for an unconfigured host*: `smd admin
heartbeat emit --dry-run` must exit 2 with the not-enabled message (exit
0 would mean a station config leaked into the golden template; any other
exit means the CLI is broken), and both awareness units must be
installed. The exit-0 path is proven on a configured station after
rollout, not here.

### 3. Blessed

`bless-release.sh <version> [--apply]` is the gate. It refuses to create a
GitHub Release unless all seven checks pass (version format, tag reachable
from `origin/main`, clean tree, verified checksum, manifest with a
components block, tied test evidence, no pre-existing Release for the tag).
Dry-run by default — `--apply` is required to create anything, and even
then only after every gate has passed.

On success it also **promotes the image out of `wd30:~/pending/`** into
the download directory — the second half of the staging rule above. A wd30
that is unreachable does not fail the bless: the GitHub Release is the
authoritative artifact and is already published by that point, so the
script warns and prints the one-line manual promotion rather than
unwinding a Release over a download convenience. See the script's own header comment
for the exact gate list and the reasoning behind gate 0 in particular (a
`--dev` build's `v0.0-dev+<sha>` stamp passes the *build* script's format
check; blessing is the only remaining backstop).

On `--apply`, the Release is created on the **public** `HamSCI/sigmond-appliance`
repo with only the manifest and `.sha256` attached (the image itself is 4.7 GB
against GitHub's 2 GiB asset cap and stays on the artifact store). Release
notes are generated, never hand-typed, and are self-checked for leakage
(hostnames, IPs, absolute paths, usernames) before publishing — the script
refuses to publish rather than guess.

### 4. Rolled

Rolling has the two orientations sigmond's `CONTRIBUTING.md` §3 defines,
and a release reaches machines through both:

- **A new machine** gets the blessed image written to a stick and
  installed following `INSTALL.md` / `QUICKSTART.txt`; firstboot lands
  the manifest at `/etc/sigmond-appliance/manifest.txt` as part of the
  install.
- **A live machine is never reimaged.** It is first brought level
  (station-inward: `smd update --apply`, on the host, through its root
  channel), then adopts the Release's manifest in place:

  ```bash
  smd admin manifest adopt <manifest.txt>                     # dry-run
  smd admin manifest adopt <manifest.txt> --allow-superset --apply
  ```

  The verb is fail-closed: it refuses unless every component matches the
  manifest exactly or is an ancestry-verified *sanctioned superset*
  (the live commit provably contains the manifest one — the
  contains-pin rule; blessed means contained baseline, not frozen
  equality), and it re-checks drift immediately after writing. Its
  first fleet run caught a unit 3 commits *behind* blessed that every
  previous process had reported as fine.

The fleet administrator (fleet-outward, on the devbox) owns the order —
canary first, verify, then the rest — and the evidence, which since
v3.33 is machine-checkable rather than per-site folklore:

- `smd fleet status --profile dasi2` reports `matches blessed manifest`
  (with any sanctioned supersets named) per host, exit 0;
- each station's heartbeat manifest block reads VALID on the fleetboard,
  so "is the fleet on the blessed baseline" stays continuously visible
  instead of being a question someone has to remember to ask.

v3.33 was the first release rolled this way — the first time any host
could answer "am I what we blessed" with yes.

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
