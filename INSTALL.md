# Sigmond Station — Installation Guide for Everyone

> **Audience:** operator
> **Status:** current
> **Verified against:** sigmond-appliance v3.69 (1c63a35) with sigmond f01e86f, image sha256 f50ffa3b…: the nested rig test and a hardware install on AC0G-ND, 2026-10-07 (the site sink switch read off until `smd sink upload`; nothing recorded while off shipped)
> **Canonical for:** burning, booting and first-boot wizard of the appliance image

Day-2 operation, troubleshooting beyond §11, remote access and what-not-to-touch live in the [Operator guide](https://github.com/HamSCI/sigmond/blob/main/docs/operator/README.md).

This walks you through turning a small computer into a complete
HamSCI/WsprDaemon receiving station. **No Linux experience needed.** You
answer a handful of questions with a keyboard, plug and unplug one USB
stick when told, and switch the machine back on twice. It does everything
else itself.

About an hour end to end, most of it waiting. The image version is printed
on the stick's QUICKSTART, in `/etc/sigmond-appliance/version` after
install, and on the first line of the console panel.

---

## 1. Gather these things first

**Hardware**
- The station computer: a modern x86-64 mini-PC or small server with
  **16 GB RAM or more** and an internal **NVMe** drive. The installer writes
  only to an NVMe drive.
  ⚠ **Everything on that internal drive will be erased.**
- A network: wired Ethernet to your site router (automatic addresses), or a
  Wi-Fi network you join during setup. IPv6-only sites work too.
- An **RX888 Mk2** SDR receiver and your antenna feed.
- A **Leo Bodnar LBE-1421 GPSDO** and its GPS antenna. It supplies the
  receiver's sampling clock and the station's timing reference.
- A **USB stick of 16 GB or more**. ⚠ Everything on it will be erased too.
- A monitor and USB keyboard on the station computer, until the wizard
  finishes.
- Any other computer (Mac, Windows, or Linux) to prepare the stick.
- Optional: an RM3100 magnetometer, a TS-1 time injector, a local
  GPS-disciplined time server. The station finds them by itself.

Plug the receiver and GPS clock in **before the first boot**. Anything
missing does not stop the install; you add it later (§7).

**Facts — write these down. The wizard asks in this order.**
| Question you'll be asked | Example |
|---|---|
| Reporter ID (callsign, optional /suffix) — required | `AC0G/B4` |
| Grid square — required; not asked if the GPS clock has a fix | `EM38ww` |
| Antenna description (optional) | `80m dipole @ 40ft` |
| Wi-Fi network and passphrase (only if no cable; asked only on a machine with Wi-Fi) | `ShackNet` |
| Is this a DASI station? Its unit number | `Y`, `3` (for DASI-003) |
| Enable remote access? | `Y` (default, recommended) |
| PSWS station ID (optional, Enter to skip) | `S000170` |
| — its GRAPE instrument ID | `171` |
| — magnetometer instrument number (if any; same station ID) | `84` |
| Send status heartbeats? | `Y` (default) |
| Station designator (Enter accepts the suggestion) | `AC0G-B4` |

⚠ **Names beginning `DASI` followed by three digits are reserved** for the
NSF-funded DASI2 fleet, and are checked against a roster shipped with the
software. If you were issued one — `DASI007`, say — use exactly that: your PSWS
station and instrument IDs come from the roster. A `DASI`-numbered name that is
*not* in the roster is **refused** rather than guessed at. If that happens,
either the name has a typo or your machine is newer than the roster — ask your
fleet admin. Any other name is an ordinary station and nothing here applies.

---

## 2. Get the image

Ask your fleet admin for the current release — or download links for it:

- `sigmond-appliance-v3.69-20261007-release.img`  (about 5.5 GB)
- `sigmond-appliance-v3.69-20261007-release.sha256`  (its checksum)

Each release carries its own version and date in the filename; use the names
you were given wherever this guide shows one.

The image is published **uncompressed** (`.img`) — there is nothing to
decompress. With both files in one folder, check it:

```
sha256sum -c sigmond-appliance-v3.69-20261007-release.sha256
```

---

## 3. Write the image to the USB stick

**Best:** the flasher from this repo. It finds the stick by its removable and
USB attributes instead of a letter you type, refuses the disk your computer
runs from, and reads the stick back to compare every byte:

```
./flash-usb.sh sigmond-appliance-v3.69-20261007-release.img
```

**Any OS, graphical:** balenaEtcher (balena.io/etcher) or Raspberry Pi Imager
("Use custom"). Both verify the write.

**Command line (Linux):**
```
lsblk -dno NAME,SIZE,TRAN,RM,MODEL     # find the stick: check size, removable
sudo dd if=sigmond-appliance-v3.69-20261007-release.img of=/dev/sdX bs=4M \
        oflag=direct conv=fsync status=progress
sync
```
⚠ Getting `/dev/sdX` wrong overwrites that machine's own disk without asking.

**Command line (Mac):**
```
diskutil list                      # find your stick, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=sigmond-appliance-v3.69-20261007-release.img of=/dev/rdisk4 bs=4m
```

**Verify a hand-written stick** by reading back exactly the image's size:
```
IMG=sigmond-appliance-v3.69-20261007-release.img
sudo head -c "$(stat -c %s $IMG)" /dev/sdX | sha256sum
sha256sum $IMG                     # the two hashes must match
```
⚠ Don't verify with `file -s` — it reads only the boot sector, so it passes a
stick that took one megabyte and fell off the bus.

After writing, your computer may show one small drive from the stick (often
"EFI" or "NO NAME"). That's normal; ignore it, or see §4.

---

## 4. Returning station? Put your old keys on the stick (optional)

Skip this for a brand-new station.

If this machine **replaces** an existing Sigmond station, save its keys on the
old station:

```
tar czf site-keys.tar.gz -C / etc/hs-uploader/keys home/timestd/.ssh
```

Copy `site-keys.tar.gz` onto that small "EFI" drive the stick shows, then eject.
The wizard restores the keys and, if you give PSWS IDs, checks the PSWS login
for you — your portal registration carries over.

---

## 5. First boot — the automatic install

1. Plug the stick into the station computer. Connect monitor, keyboard,
   receiver, GPS clock, and Ethernet.
2. Power on and **boot from the stick** — press the boot-menu key as it
   starts (usually F7, F11, F12, or Del) and pick the USB entry. If no menu
   appears, enter BIOS setup and turn **Fast Boot OFF**.
3. **What you'll see:** an installer runs by itself, asking nothing. After a
   few minutes **the machine turns itself off**. That is your signal.

   ⚠ **It can sit on "creating LVs" for a long time** when the disk held an
   earlier install. That is the installer working, not a hang. **Do not
   switch the machine off** — wait at least 30 minutes. Cutting power there
   only makes you start again (AC0G-ND, 2026-10-05: the first attempt was
   switched off at this step; the second, left alone, finished).
4. **REMOVE THE STICK, then power the machine back on.** (Some machines
   always boot USB first and would install again in a loop.)

---

## 6. Second boot — put the stick back

The machine starts from its own disk. The console shows that Proxmox is
running, its address and login, and:

```
 NEXT STEP: plug in the Sigmond install USB stick.
 The decoder VM then installs itself automatically.
```

Plug **the same stick** back in, into any port. The console answers:

```
 Sigmond USB detected (...).
 Importing the decoder VM (~3 min). LEAVE THE STICK IN.
```

Leave it in.

---

## 7. Answer the setup questions

The setup wizard appears on the monitor. It first lists the equipment it found
— RX888, GPSDO, TS-1, magnetometer — and says plainly that anything missing does
not stop the install. Then it asks the questions from §1, in that order. Type
answers and press Enter; press just Enter to accept a suggestion or skip an
optional item.

At the end a **review screen** shows everything you typed — type a line number
to fix any answer, then `Y` to apply.

The wizard then configures everything itself (a few minutes).

If the receiver or another device was missing, the station installs anyway and
waits, dormant — nothing is lost. Plug it in (the RX888 in a **blue** USB-3 port,
straight into the machine, no hub), then bring it up:

```
sigmond-vm smd status          # the device appears under "adoptable:"
sigmond-vm smd adopt <name>    # use the name smd status printed; it asks first
```

The same two commands add *any* hardware later. The station reports what it
finds and starts nothing until you ask.

(If the remote-access line says FAILED, don't worry — the support server may be
busy. Turn it on later with `sigmond-setup --reconfigure`.)

---

## 8. Remove the stick — it powers off — switch it back on

The host tunes itself (CPU isolation, USB passthrough to the decoder VM), then
the console prints:

```
 >>> INSTALL COMPLETE — REMOVE THE USB STICK NOW <<<
 As soon as the stick is removed this machine POWERS OFF.
```

Pull the stick. The machine **switches off** — it does not reboot. **Switch it
back on.** That full power-off also resets the RX888, which it needs.

While the console panel says **STATION IS STILL BUILDING**, leave it alone; on a
fresh machine that can take tens of minutes.

⚠ **After this the keyboard on the station computer may go dead. That is normal
and correct** — the USB ports now belong to the radio, and the panel says the
console is read-only. From here on you use the station from another computer.
The panel lists every address and login; disconnect the monitor and keyboard
whenever you like.

---

## 9. Fifteen minutes later — check it's alive

From any computer on the same network (addresses are on the console panel):

- **Live receiver:** `http://<host address>:8081` — a waterfall with signals.
- **Station pages:** `http://<host address>:8000` — the station's callsign and grid,
  and its timing and GRAPE pages.
- **Magnetometer:** `http://<host address>:8082` (if you have one)

The decoder VM sits on a private link behind the host, so the host relays these pages for it.

**No spots or PSWS data leave the station yet.**  A new station starts with its site sink
switch at `off`.  It records and decodes, but sends no spots or data to wsprnet,
pskreporter.info, wsprdaemon.org or PSWS.  Only its heartbeat, a five-minute health report
for the fleet board, goes out.

Log in to the decoder VM (§10) and check three things:

```
smd watch wspr      # a line per 2-minute cycle counting the WSPR spots it decoded; Ctrl-C stops it
smd watch psk       # the same for FT8 and FT4, every 15 seconds
grep -E 'reporter_id|callsign|grid' /etc/sigmond/site-profile.toml
```

When the waterfall shows signals, the watchers count spots, and the reporter ID, callsign
and grid read right, read the site sink switch:

```
smd sink status
```

A new station says `site sink: off` and gives the reason `new station: …`.  Any other
reason means someone set the switch on purpose.  Leave it alone and ask your fleet admin.

With the reason `new station: …`, set the site sink switch to `upload`:

```
smd sink upload
smd sink status     # should say: site sink: upload
```

Nothing recorded before `smd sink upload` leaves the station, with one exception.  The
station packs each UTC day's GRAPE and magnetometer data after that day ends, between
01:00 and about 05:00 UTC.  So the packages for the UTC day you run it still go out, and
so do the previous day's if you run it before that packing has finished.  Run it after
about 05:00 UTC if you can.  While a packing job runs, `smd sink upload` refuses, names
the job, and asks you to run it again when the job ends.  About fifteen minutes after
`smd sink upload`, search your reporter ID at wsprnet.org (Database) and your callsign at
pskreporter.info.

---

## 10. Logins — and change the password

**One password unlocks the whole station.** It starts as **`hamsci-sigmond`**.
The wizard copies the host's root password to the decoder VM's `sigmond`,
`hamsci` and `root` accounts, so they all take the same one. Root login over
SSH stays off on the VM.

| Where | How |
|---|---|
| Proxmox host (the machine itself) | `ssh root@<host address>` or browse `https://<host address>:8006` |
| Decoder VM (the radio) | `ssh -p 2222 sigmond@<host address>` (relayed by the host), or `ssh sigmond@<VM address>` (also `hamsci@`) |

Change it: run `passwd` on the host, and in the VM.

**PSWS stations:** the VM's login banner shows this machine's public upload key.
Paste it into the PSWS portal for your station
(https://pswsnetwork.eng.ua.edu/), then run `smd psws verify`. Until then the
station keeps recording locally. Packages built after you run `smd sink upload`
wait on the station and ship once the key verifies. Packages built before that
command stay on the station in a held folder and never ship (§9). **One key
serves the whole machine:** if it uploads for more than one station, register
the same key on each. (If you restored keys in §4, this is already done.)

---

## 11. If something goes wrong

| Symptom | Fix |
|---|---|
| Machine ignores the stick / boots its old OS | Re-write and verify the stick (§3); try another USB port; turn off Fast Boot in BIOS; use the boot-menu key |
| `INSTALL CANNOT CONTINUE NORMALLY: …` on the console | No working network. Its title says which case (no cable / connected but nothing answered / no address offered). Move the cable to a port with a link light and reboot; or set a fixed address, `sigmond-setnet 10.0.0.50/24 10.0.0.1`; or use Wi-Fi, `sigmond-wifi scan` then `sigmond-wifi join <network>` |
| `import: no Sigmond USB present` | Plug the stick back in — any port, machine running |
| Wizard: no RX888 found | Not a failure — the station installs dormant. Re-seat the cable in a **blue** port, then `sigmond-vm smd status` and `sigmond-vm smd adopt <name>` |
| Installer stuck on "creating LVs" | Usually not stuck — on a disk that held an earlier install it can take many minutes. Wait at least 30 minutes before switching off |
| Receiver found, but nothing decodes; the VM log says `RX888 ADC clock not locked/running` | Unplug the USB 3 cable **at the RX888** and plug it firmly back in. A badly seated plug looks exactly like a missing clock, and cycling power does not cure it (AC0G-ND, 2026-10-05) |
| Stick still in an hour after "REMOVE THE USB STICK NOW" | Remove it, run `poweroff`, then power the machine back on |
| Typed a wrong answer | From the host: `sigmond-setup --reconfigure` |
| Remote access shows FAILED | Later, from the host: `sigmond-setup --reconfigure` |
| No spots after 30 minutes | Expected on a new station until you run `smd sink upload` (§9). Log in to the VM and run `smd sink status`. If it says `site sink: off` with the reason `new station: …`, check the station as §9 describes, then run `smd sink upload`. If it says `site sink: off` with any other reason, or `hold (legacy)`, ask your fleet admin. If it says `site sink: upload`: antenna actually connected? Then run `smd status` and send its output to your fleet admin |
| Anything else | If you enabled remote access, your fleet admin can log in and fix it — just ask |

More symptoms and the decision tree: [operator troubleshooting](https://github.com/HamSCI/sigmond/blob/main/docs/operator/troubleshooting.md).

---

*Fleet-internal: blessed images live in the download folder on wd30 and on the
release Drive folders (untested builds sit in `pending/` until blessed). This
document lives in the HamSCI/sigmond-appliance repo as `INSTALL.md` — keep it
updated as the wizard changes.*

---

## 12. Moving a station (staged in one place, deployed in another)

Stations are often built and tested at one site (wrong grid square!) and
then shipped to their permanent home. Keep the site sink switch at `off`
until the station knows where it stands:

1. At the staging site, leave the site sink switch at `off`; a new station
   starts that way. Check reception there with the waterfall and
   `smd watch wspr` (§9). No data leaves the station; only its heartbeat
   goes out.
2. At the destination, log into the **Proxmox host** (`ssh root@<host address>`,
   or the console before the USB controllers were handed to the VM) and run
   `sigmond-setup --reconfigure`.
3. Answer the questions again. The wizard asks for your reporter ID and PSWS
   ids afresh, and pressing Enter at the PSWS station ID skips PSWS, so have
   them at hand. Type the **new grid square**. A station whose GPSDO has a fix
   fills in the grid by itself, and may already have moved the grid; check it
   on the review screen. The wizard keeps your remote-access number and the
   site sink switch as they were.
4. Log in to the decoder VM and check the identity:
   `grep -E 'reporter_id|callsign|grid' /etc/sigmond/site-profile.toml`.
   (The station pages keep the grid from the first install.) Then run
   `smd sink status`. If it says `site sink: upload`, someone raised the
   switch earlier; verify on wsprnet after about 15 minutes. If it gives any
   reason but `new station: …`, or says `hold (legacy)`, someone set the
   switch on purpose; ask your fleet admin. If it still gives the reason
   `new station: …`, run `smd sink upload` (§9 explains the packing window),
   then verify on wsprnet after about 15 minutes.
