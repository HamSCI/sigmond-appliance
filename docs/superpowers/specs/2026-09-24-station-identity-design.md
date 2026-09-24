# A station keeps its identity across a reflash

> **Audience:** contributor
> **Status:** design — approved in conversation 2026-09-24, awaiting review of this text
> **Spans:** sigmond (the file list, export, restore), sigmond-appliance (firstboot, wizard, nested test), the operators' private ops repository (capture, check, stick)
> **Needs sign-off from:** Rob, for §5 (the RAC credential), which lands inside his `sigmond-rac-register` extraction

## 1. What happened

On 2026-09-23 we reflashed AC0G-B4 from v3.51 to v3.52.  The install itself went cleanly.  Bring-up finished without a single lifecycle-lock collision, and T6 reached AUTHORITATIVE within a minute.

Then everything that had learned to trust the old machine stopped trusting the new one.  Our `known_hosts` rejected the changed host keys on both planes.  The heartbeat server on wd30 refused the new uploader key, so the fleet board lost B4.  PSWS will refuse the same key until someone pastes it into the portal again.  The RAC registrar issued a fresh credential, and the old one now sits on gw2 as a set of offline entries nobody will clean up.  We repaired each of these by hand, one at a time, and only the ones we noticed.

None of this reflects a fault in the new install.  The install did what it does: it minted a new identity.  The fault lies in treating identity as a property of the install, when it belongs to the station.  A reflashed B4 stands on the same bench, hears the same signals and uploads under the same station id.  It should present the same keys.

INSTALL.md step 4 already offers a way to carry keys across: tar two directories on the old station and drop the tarball on the stick.  That path covers the uploader keys and nothing else, and it depends on someone remembering to run a command before the wipe.  On B4 nobody did.  The pre-flash capture that morning saved six weeks of timing data and the radiod tuning, and no keys at all.

## 2. What counts as identity

Identity here means material the station minted that other parties have since learned to trust.  Configuration and data stay out; site-deltas and pre-flash captures already carry those.

| Plane | Material | Who minted it | Who trusts it |
|---|---|---|---|
| VM | `/etc/ssh/ssh_host_*` | the OS install | every operator's `known_hosts`, the PM's `vm-known_hosts` |
| VM | `/etc/hs-uploader/keys/` | the wizard | the wd30 heartbeat account, PSWS |
| VM | `/home/timestd/.ssh/id_*` | older installs | PSWS (legacy per-recorder key) |
| PM | `/etc/ssh/ssh_host_*` | the Proxmox install | every operator's `known_hosts` |
| PM | `/root/.ssh/id_ed25519` (+ `.pub`) | the Proxmox install / sigmond setup | the VM's sigmond account, for the PM→VM hop; sent as `[metadatas] pubkey` on every RAC login |
| PM | the RAC `user` and token in `/etc/sigmond/frpc-host.toml` | the RAC registrar | gw2's frps |

The RAC row carries only the credential lines, not the whole file.  The wizard regenerates the proxy list from the station's layout, and a restored list could contradict a changed layout.

## 3. The bundle

Each station gets two files in the ops repository:

```
site-deltas/<site>/identity.age        # tar of both planes, encrypted
site-deltas/<site>/identity.manifest   # path, owner, mode, fingerprint — no secrets
```

`age` encrypts the tar to every key in `sigmond-appliance/operators/*.pub`.  `age` accepts SSH public keys, Rob's RSA key included, so each operator decrypts with the key already on their laptop.  No second key set to manage, and adding a person to `operators/` then re-capturing gives them access.

The manifest stays in plaintext beside the ciphertext.  It lets anyone ask whether a live station still matches its bundle without decrypting anything.

Plaintext stays in memory on the devbox, from the ssh read to the age encrypt.  It touches disk only on the stick, for the length of a reflash.

The bundle's own format — member naming, ownership by name and numeric id together, why a restore must not use tarfile's `data` extraction filter, member order — has its own account: the "Bundle format (schema 1)" section of `sigmond/lib/sigmond/identity.py`'s module docstring.  The manifest also carries two keys beyond the file list: `identity_py_sha256`, the digest of the identity.py source that ran the capture, and `recipients`, the fingerprints of every operator key the bundle was encrypted to.

One limit deserves plain statement.  Git keeps history, so an old `identity.age` stays decryptable by whoever could decrypt it then.  Removing an operator protects future bundles only.  Anyone who needs a clean break must rotate the station's keys and re-capture.

## 4. The commands

sigmond defines the identity file list once, in `sigmond/lib/sigmond/identity.py`.  The export at capture time and the restore at install time both read that one list, so the two cannot drift apart.  Drift explains the present step-4 tarball: somebody wrote its list by hand, in a document, and it never grew when the station did.

### On the station (sigmond)

- `export --plane vm|pm` writes a tar of that plane's identity files, manifest included, to stdout.  It reads and changes nothing.
- `fingerprints --plane vm|pm` prints the manifest alone.  It still needs root: it hashes private key halves too, reads directories such as `/home/timestd/.ssh` that sit at 0700, and reads the RAC token to fingerprint it.
- `restore <tarball>` installs the files with their recorded owners and modes, and reports each item as restored, absent or failed.

### On the devbox (ops repository, `bin/site-identity`)

- `capture <site>` reads both planes over ssh, encrypts, writes the two files and commits.  It runs once after bring-up, and again after anyone rotates a key by hand.  It builds its reach from the same fleet inventory `fleet-ssh` itself reads, rather than calling `fleet-ssh`.  A fresh export that differs from the site's already-committed manifest refuses, and writes nothing, unless `--rebaseline` accepts the change; an identical re-capture always proceeds.  Before writing anything it also proves the new bundle decrypts, with a local `~/.ssh/id_*` key that matches one of the operator recipients; finding none refuses the capture, unless `--no-verify` accepts the gap and prints a loud warning instead.
- `check <site>` compares live fingerprints against the committed manifest.  Exit 0 means a match; 1 names every differing item; 2 means the site carries no committed bundle yet; 3 means ssh could not reach the live station at all.  It never decrypts.
- `stick <site> <efi-mount>` decrypts onto the stick as `site-keys.tar.gz`, and runs `check` first:
  - exit 0 (match) — it proceeds;
  - exit 1 (mismatch) — it refuses; the bundle has gone stale, re-capture first;
  - exit 2 (no bundle) — it refuses; no bundle exists yet to decrypt, capture first;
  - exit 3 (unreachable) — it proceeds with a loud warning, from the last bundle.

The fourth case covers the reason the whole design exists: a dead disk or a replaced machine, with no chance of a last-minute capture.

The rule "check before you wipe" lives inside `stick`, not in a checklist.  Nobody can build a restore stick from a stale bundle without the command saying so.

INSTALL.md step 4 gets rewritten around `site-identity stick`, and loses its hand-typed `tar czf` line.

Plan 1 wires none of this as `smd admin identity` yet — the PM carries no smd at all, and a station's sigmond checkout may predate this module.  `capture` and `check` instead pipe `identity.py`'s own source over ssh, and run it directly as `python3 - export --plane ...` / `python3 - fingerprints --plane ...`.  Wiring `export`/`fingerprints`/`restore` as real `smd admin identity` verbs is Plan 2's work, alongside the restore path itself.

## 5. Restoring at install

`firstboot-v3.sh` already copies `site-keys.tar.gz` off the stick's EFI partition, and the wizard already restores the uploader keys into the VM.  Both steps change to call `smd admin identity restore`.

On the PM, firstboot:

1. copies the tarball off the stick, remounts the EFI partition read-write and deletes the tarball there;
2. installs the PM host keys and restarts sshd — nobody has connected yet, so the restart costs nothing;
3. holds the RAC credential for the wizard.

In the VM, the wizard:

4. installs the VM host keys and the uploader keys, then restarts sshd;
5. writes the restored RAC `user` and token into `frpc-host.toml`, starts frpc and skips the registrar call.

gw2 then sees the station return under its old name.  No new entries appear, and none go stale.

Step 5 touches the code Rob deliberately deferred: the one-shot RAC block in the wizard that he plans to extract into `sigmond-rac-register`.  This design proposes one branch for that extraction, taken first: a restored credential present means reuse it; otherwise register.  His extraction and this change should land as one piece of work, not as two changes competing for the same block.

After the VM restore finishes, firstboot deletes the staged copy from the PM's disk.

Because firstboot deletes the stick's copy early, an install that fails and must start over needs the tarball put back.  The operator runs `site-identity stick` again; the bundle in git remains the source.

### When a restore fails

The station still comes up, and mints fresh material wherever the restore failed.  A remote station that refuses to boot costs more than one with new keys.  The failure never stays quiet, though.  The console panel shows `IDENTITY RESTORE FAILED — new keys minted: …` with the failed items named, the heartbeat carries the same finding, and `site-identity check` fails from the devbox until someone re-captures.

Silent minting produced every problem in §1.  So the minting path must always announce itself.

## 6. Testing

Each test counts only after someone has watched it fail.

- sigmond unit tests for `identity.py`: export and restore against a temporary root, the manifest format, owners and modes preserved.  Mutation check: drop the host keys from the file list, and the round-trip test must fail.
- ops tests for `site-identity`: an `age` round-trip with a throwaway operator key; `check` exits non-zero on each kind of mismatch; `stick` refuses a stale bundle.
- `test-nested-v3.sh` already stages a fake site-keys tarball.  It becomes a real round trip: install A and capture it; reinstall as B from a stick that `site-identity stick` made; assert that `check` passes, that the wizard never called the registrar and that gw2 shows no new name.  Then corrupt one file in the bundle and assert that both the panel and the heartbeat report the failure.

## 7. Order of work

Each step delivers something by itself.

1. sigmond `identity.py`, with `export` and `fingerprints`.  Both only read, so they can go to live stations at once.
2. `site-identity capture` and `check` (the devbox needs the `age` package first), then a capture of every station now: B4, AC0G-ND, AI6VN, DASI002.  B4's new identity becomes its baseline.  The others gain cover before their next reflash, which alone would have prevented most of §1.
3. The restore path in firstboot and the wizard, with the nested round trip.  This ships in v3.53.
4. The RAC reuse branch, with Rob, inside `sigmond-rac-register`.

## 8. Out of scope, and why

- SSH certificates.  A HamSCI signing key could vouch for host keys and operator keys, which would end `known_hosts` churn even for brand-new stations.  It also creates a signing key that needs guarding.  It stays a candidate for later; this design removes the churn for the stations we already have.
- A brand-new station's first enrollment.  A new station has no old identity to keep.  Its first registration with wd30 and PSWS stays as it works today, and `capture` records the result.
- Cleaning up the stale gw2 entries from past reflashes.  That falls to the registrar, not the station.
