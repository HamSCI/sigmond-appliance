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

### 3. Blessed

`bless-release.sh <version> [--apply]` is the gate. It refuses to create a
GitHub Release unless all seven checks pass (version format, tag reachable
from `origin/main`, clean tree, verified checksum, manifest with a
components block, tied test evidence, no pre-existing Release for the tag).
Dry-run by default — `--apply` is required to create anything, and even
then only after every gate has passed. See the script's own header comment
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

A blessed image is written to a stick and installed on a real (or nested)
target, following `INSTALL.md` / `QUICKSTART.txt`. Evidence a version is
"rolled" lives outside this repo, per-site — this document does not define
it, since rollout is a fleet/operations concern rather than a build-rig one.

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
