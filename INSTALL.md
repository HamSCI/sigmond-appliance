# Sigmond Station — Installation Guide for Everyone

This walks you through turning a small computer into a complete
HamSCI/WsprDaemon receiving station. **No Linux experience needed.** You
answer about six questions with a keyboard, plug and unplug one USB
stick when told, and the machine does everything else itself.

Total hands-on time: about 20 minutes. Written for appliance image
**v3.16** (any machine will tell you its version with
`cat /etc/sigmond-appliance/version`, and it's the first line of the
login screen).

---

## 1. Gather these things first

**Hardware**
- The station computer: a modern x86-64 mini-PC or small server with
  **16 GB RAM or more** and an internal NVMe/SSD drive.
  ⚠ **Everything on that internal drive will be erased.**
- Wired Ethernet from the computer to your home/site router (the normal
  kind of network with automatic addresses and internet — if other
  devices "just work" when plugged in, you're fine).
- An **RX888 Mk2** SDR receiver and your antenna feed.
- A **USB stick, 8 GB or larger** (16–32 GB ideal).
  ⚠ Everything on the stick will be erased too.
- A monitor and USB keyboard plugged into the station computer — you
  need them once, for the setup questions.
- Any other computer (Mac, Windows, or Linux) to prepare the stick.
- Optional extras the station finds by itself if present: Leo Bodnar
  GPSDO, RM3100 magnetometer, a local GPS-disciplined time server.

**Facts — write these down before you start**
| Question you'll be asked | Example |
|---|---|
| Reporter ID (callsign, optional /suffix) | `AC0G/B4` |
| Grid square (6 characters) | `EM38ww` |
| Antenna description (free text, optional) | `80m dipole @ 40ft` |
| Enable remote support access? | `Y` (recommended) |
| PSWS station ID (optional, skip with Enter) | `S000170` |
| — its GRAPE instrument number | `171` |
| — magnetometer device (if any) | `RM3100` |
| — magnetometer's own PSWS station (if different) | `S000082` |
| Station name (Enter accepts the suggestion) | `AC0G-B4` |

---

## 2. Get the image

Ask your fleet admin for the current release — two files:

- `sigmond-appliance-v3.16-20260730.img`  (about 5 GB)
- `sigmond-appliance-v3.16-20260730.sha256`  (its checksum)

If what you received ends in **`.img.xz`, decompress it first** (Mac:
double-click it; Windows: right-click → 7-Zip → Extract). **Never write
the compressed file to the stick** — that is the single most common
installation failure, and the machine gives no error, it just silently
doesn't boot.

---

## 3. Write the image to the USB stick

Easiest reliable way on any OS: **balenaEtcher** (free,
balena.io/etcher). Select the **`.img`** file, select your stick, Flash.
Etcher verifies the write for you.

Command-line alternative (Mac):
```
diskutil list                      # find your stick, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=sigmond-appliance-v3.16-20260730.img of=/dev/rdisk4 bs=4m
```

After writing, your computer may pop up one small drive (often called
"EFI" or "NO NAME") — that's normal, ignore it (or see step 4).

---

## 4. Returning station? Put your old keys on the stick (optional)

Skip this for a brand-new station.

If this machine **replaces** an existing Sigmond station and you saved
its keys (`tar czf site-keys.tar.gz -C / etc/hs-uploader/keys
home/timestd/.ssh` on the old station), copy `site-keys.tar.gz` onto
that small "EFI" drive the stick shows after burning, then eject. The
installer will restore them automatically and your PSWS portal
registration carries over.

---

## 5. First boot — the automatic install (~10 minutes)

1. Plug the stick into the station computer. Connect monitor, keyboard,
   and Ethernet.
2. Power on and **boot from the stick** — press the boot-menu key as it
   starts (usually F7, F11, F12, or Del, it varies by machine) and pick
   the USB entry. If no menu appears, enter BIOS setup and turn **Fast
   Boot OFF**, then try again.
3. **What you'll see:** an installer runs entirely by itself — no
   questions. After roughly 10 minutes **the machine turns itself
   off**. That shutdown is your signal:
4. **REMOVE THE STICK.** (Booting with it still inserted can restart
   the installer.)

---

## 6. Second boot — plug things back in

1. Power the machine on (stick out). After a minute the screen shows
   the system is running and its network address.
2. Make sure the **RX888 is plugged into a blue USB-3 port** now.
3. **Plug the USB stick back in** (any port, machine stays on).
4. **What you'll see:** the screen announces
   `Sigmond USB detected — importing the decoder VM (~3 min). LEAVE THE STICK IN.`
   Do what it says: leave it in.

---

## 7. Answer the setup questions

The setup wizard appears on the monitor and asks the questions from
your list in step 1. Type answers and press Enter; press just Enter to
accept a suggestion or skip an optional item.

At the end you get a **review screen** showing everything you typed —
type a line number to fix any answer, then `Y` to apply.

The wizard then configures everything itself (a few minutes). Watch for
this line:

```
SDR/radiod: radiod ACTIVE ✓
```

If it instead asks you to plug in or re-seat the RX888, do that — the
station recovers by itself within two minutes.

(If the remote-access line says FAILED, don't worry — the support
server may be busy; the station works fine and you can enable it later
with one command: `sigmond-setup --reconfigure`.)

---

## 8. Remove the stick when told — done

The console prints:

```
>>> REMOVE THE USB STICK NOW <<<
```

Pull it. The machine reboots itself into full production.

⚠ **After this reboot the keyboard on the station computer may go
dead. That is normal and correct** — the USB ports now belong to the
radio. From here on you use the station from another computer over the
network. The monitor shows a login panel with both addresses and
logins; you can disconnect monitor and keyboard whenever you like.

---

## 9. Fifteen minutes later — check it's alive

From any computer on the same network (addresses are on the station's
monitor panel):

- **Live receiver:** `http://<VM address>:8081` — you should see a
  waterfall with signals.
- **Your spots:** search your reporter ID at wsprnet.org (Database) and
  your callsign at pskreporter.info.
- **Timing dashboard:** `http://<VM address>:8000`

---

## 10. Logins — and change the password

One password unlocks everything on the appliance. Factory default:
**`hamsci-sigmond`** — change it once you're up.

| Where | How |
|---|---|
| Proxmox host (the machine itself) | `ssh root@<host address>` or browse `https://<host address>:8006` |
| Decoder VM (the radio) | `ssh hamsci@<VM address>` (or `sigmond@`) |

To change the password, run `passwd` in each place you log in (host
root, and hamsci/sigmond in the VM).

**PSWS stations:** the VM's login banner shows the upload key to paste
at https://pswsnetwork.eng.ua.edu/ — then run `smd psws verify`. Until
then data records locally, nothing is lost. (If you restored keys in
step 4, this is already done.)

---

## 11. If something goes wrong

| Symptom | Fix |
|---|---|
| Machine ignores the stick / boots its old OS | Re-burn using the **decompressed** `.img` (not `.xz`); try another USB port; turn off Fast Boot in BIOS; use the boot-menu key |
| Installer finished but screen is stuck, stick still in | Remove the stick, power-cycle |
| `no Sigmond USB present` on screen | Plug the stick back in — any port, machine running |
| Wizard: no RX888 found | Re-seat the RX888's USB cable in a **blue** port; it retries automatically every 2 minutes |
| Typed a wrong answer | From the host: `sigmond-setup --reconfigure` |
| Remote access shows FAILED | Later, from the host: `sigmond-setup --reconfigure` |
| No spots after 30 minutes | Antenna actually connected? Then `ssh hamsci@<VM>` and run `smd status` — send its output to your fleet admin |
| Anything else | If you enabled remote access, your fleet admin can log in and fix it — just ask |

---

*Fleet-internal: images live on wd30 (`~/sigmond-appliance-*.img` +
`.sha256`). This document lives in the HamSCI/sigmond-appliance repo as
`INSTALL.md` — keep it updated as the wizard changes.*
