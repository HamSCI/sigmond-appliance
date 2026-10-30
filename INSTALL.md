# Sigmond Station — Installation Guide for Everyone

> **Audience:** operator
> **Status:** current
> **Verified against:** sigmond-appliance v3.84: v3.83 plus an update fix, a command reference, a new time-source question, and no heartbeat.  `smd align` now builds the UberSDR decoders when a station lacks their source, which stopped AC0G-ND's update on 10-28.  `smd admin cli-reference` records every station command, and the station pages show it under Commands, next to Documentation in the top bar.  hs-uploader finds its store by one rule, and its installer names the store in `/etc/hs-uploader/sink.toml`; the clients take their sink writer from hs-uploader.  The client installers keep any Python that uv downloads in `/opt/uv/python`.  Rob's wizard changes: the wizard no longer asks about status heartbeats and turns both heartbeat timers off, so no station opens a connection to wd30; it asks for a local NTP server, and without one it uses a public pool capped at four servers; it takes the grid from the GPS clock's position, the LBE-Mini's included.  Rob's remote-access fixes clear a gateway the station no longer uses.  The rig's nested test installed v3.84 from scratch, and its update test carried a v3.83 station forward to this code and back.  ⚠ **No station has yet installed v3.84 from scratch on hardware**, and no station has yet updated to it in place.  The v3.83 note follows.  sigmond-appliance v3.83: v3.82 plus three fixes and Rob's boot fixes.  `smd update` and `smd align` now run a component's deploy.toml build when it has no `install.sh`, so station-web and hamsci-physics get their new dependencies; each v3.82 station rebuilds those two once on its first update.  Install probes the magnetometer's I2C addresses every time and writes what answers, and the recorder refuses all-zero samples.  `smd psws save-keys` and `smd psws restore-keys` carry a station's upload keys across a reflash (§4).  Turning remote access off now also stops the old single-gateway tunnel service on a two-gateway station, so off survives a reboot.  Rob's fixes cover DNS and dhclient at boot, the power key, the console panel, wspr-recorder and psk-recorder.  The rig's nested test installed v3.83 from scratch, and its update test carried a v3.82 station forward to this code and back; station-web rebuilt and answered after the update.  ⚠ **No station has yet installed v3.83 from scratch on hardware**, and no station has yet run `smd update` then `smd align` from v3.82 on hardware.  The v3.82 note follows.  sigmond-appliance v3.82: v3.81 plus a menu at the console, colour on the console panel, and five fixes.  A root login at the station's own screen and keyboard now opens a menu (§8).  The panel shows addresses in cyan, logins in green and the starting password in yellow.  Bring-up no longer pulls any repository, so a station installs the commits its image carries.  `smd update` now passes `--yes` to each installer, so hf-timestd's setup wizard waits instead of stopping the update.  A rollback puts back any `uv.lock` an installer rewrote.  psk-recorder gets a private, writable `/tmp`.  The wspr-uploader warning about a stale links record now names the one file to delete.  The rig's nested test installed v3.82 from scratch, and its update test carried a v3.81 station forward to this code and back with no exception.  ⚠ **No station has yet installed v3.82 from scratch on hardware**, and no one has yet seen the menu or the colours on a real monitor.  The v3.81 note follows.  sigmond-appliance v3.81: v3.78 plus sink-control step 2b part 2 (sigmond writes each client's upload switch into `pipelines.d/` and `site.toml` together, and `smd sink off` stops a linked wspr-uploader rather than disabling it), Rob's UberSDR builds of wsprd and jt9 as the default decoders, `smd watch usb`, and two install fixes: hf-timestd's chrony script now carries its execute bit, and superdarn-sounder's install no longer rewrites its own `uv.lock`.  The rig's nested test installed v3.81 from scratch, and its update test carried a v3.78 station forward to this code and back.  ⚠ **No station has yet installed v3.81 from scratch on hardware.**  ⚠ Rolling a station back to v3.78 leaves superdarn-sounder's `uv.lock` modified; v3.82 fixes this.  The v3.78 note follows.  sigmond-appliance v3.78: v3.77 plus sink-control step 2b part 1 (hs-uploader reads `pipelines.d/`, its store moves to version 3, and nothing a station sends changes), the pairing fix for sudo-rs hosts, and Rob's RX888 recovery changes.  v3.77 added the `smd restart <client>` fix to v3.76.  Michael installed v3.78 from scratch on AC0G-B4 on 2026-10-22: bring-up finished `ok` with every service running (one RX888 replug behind a new hub).  ⚠ **No IPv6-only site has yet installed v3.78 from scratch**; the IPv6 fix it carries was proven by hand on a live IPv6-only station.  The v3.76 note follows.  sigmond-appliance v3.76 (built from 4b7ce17): v3.75 was installed on hardware by AI6VN (2026-10-21) at a WIRED IPv6-ONLY site and came up **unreachable** — a forwarding Proxmox host drops every router advertisement unless `accept_ra` is 2, so the station lost its IPv6 default route and never learned the RA's DNS64 resolver, and remote access could not resolve its own server name.  v3.76 is v3.75 plus that fix, which was proven on the live station by hand (the default route and the RDNSS server returned within seconds).  ⚠ **v3.76 has not yet been installed from scratch**; the nested rig test does not exercise this path, because it runs dual-stack with working DNS.  ⛔ Do not install v3.74 or v3.75 at a site with no IPv4.
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
| PSWS station ID (optional, Enter to skip) | `S000170` |
| — its GRAPE instrument ID | `171` |
| — magnetometer instrument number (if any; same station ID) | `84` |
| Local NTP server (Enter: the one your network offers, or none) | `ntp.example.edu` |
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

- `sigmond-appliance-v3.84-20261030-release.img`  (about 5.7 GB)
- `sigmond-appliance-v3.84-20261030-release.sha256`  (its checksum)

Each release carries its own version and date in the filename; use the names
you were given wherever this guide shows one.

The image is published **uncompressed** (`.img`) — there is nothing to
decompress. With both files in one folder, check it:

```
sha256sum -c sigmond-appliance-v3.84-20261030-release.sha256
```

---

## 3. Write the image to the USB stick

**Best:** the flasher from this repo. It finds the stick by its removable and
USB attributes instead of a letter you type, refuses the disk your computer
runs from, and reads the stick back to compare every byte:

```
./flash-usb.sh sigmond-appliance-v3.84-20261030-release.img
```

**Any OS, graphical:** balenaEtcher (balena.io/etcher) or Raspberry Pi Imager
("Use custom"). Both verify the write.

**Command line (Linux):**
```
lsblk -dno NAME,SIZE,TRAN,RM,MODEL     # find the stick: check size, removable
sudo dd if=sigmond-appliance-v3.84-20261030-release.img of=/dev/sdX bs=4M \
        oflag=direct conv=fsync status=progress
sync
```
⚠ Getting `/dev/sdX` wrong overwrites that machine's own disk without asking.

**Command line (Mac):**
```
diskutil list                      # find your stick, e.g. /dev/disk4
diskutil unmountDisk /dev/disk4
sudo dd if=sigmond-appliance-v3.84-20261030-release.img of=/dev/rdisk4 bs=4m
```

**Verify a hand-written stick** by reading back exactly the image's size:
```
IMG=sigmond-appliance-v3.84-20261030-release.img
sudo head -c "$(stat -c %s $IMG)" /dev/sdX | sha256sum
sha256sum $IMG                     # the two hashes must match
```
⚠ Don't verify with `file -s` — it reads only the boot sector, so it passes a
stick that took one megabyte and fell off the bus.

After writing, your computer may show one small drive from the stick (often
"EFI" or "NO NAME"). That's normal; ignore it, or see §4.

---

## 4. Reflashing or replacing a station (keep its keys)

Skip this for a brand-new station.

A reflash or a replacement wipes the station's upload keys. Without them, PSWS
refuses the new install's uploads. Save the keys first, and check them at the end.

1. **Before the flash, on the old station,** run:

   ```
   smd psws save-keys
   ```

   This writes `site-keys.tar.gz` into your home directory. Copy that file off
   the station. A station on v3.82 or older has no `save-keys`; use the `tar`
   fallback below instead.
2. **After you write the stick,** copy `site-keys.tar.gz` onto the small "EFI"
   drive the stick shows. Then eject. The installer restores the keys and, if you
   give PSWS IDs, checks the PSWS login for you.
3. **If the file missed the stick,** copy it to the new station and run:

   ```
   smd psws restore-keys site-keys.tar.gz
   ```

   This puts the keys back with the right owners and then runs the check.
4. **Finish with** `smd psws verify`. It must report the key as verified. If it
   does not, the station records but cannot upload.

The file holds the station's private keys. Once the new station verifies, delete
it from every place you copied it, and keep the stick private until then.

The old station runs v3.82 or older and has no `save-keys`? Make the file by hand. The key files belong to another user, so `sudo` runs the `tar`:

```
sudo sh -c 'umask 077; tar czf "$1" -C / etc/hs-uploader/keys home/timestd/.ssh' sh ~/site-keys.tar.gz
sudo chown "$USER" ~/site-keys.tar.gz
```

---

## 5. First boot — the automatic install

1. Plug the stick into the station computer. Connect monitor, keyboard,
   receiver, GPS clock, and Ethernet.
2. Power on and **boot from the stick** — press the boot-menu key as it
   starts (usually F7, F11, F12, or Del) and pick the USB entry. If no menu
   appears, enter BIOS setup and turn **Fast Boot OFF**.
3. **A boot menu appears, counting down from 60 seconds.** The first entry
   is highlighted and reads:

       Install Sigmond: ERASES THE INTERNAL DISK

   Leave it alone and it starts after the countdown. ⚠ **It means what it
   says:** it erases everything on the machine's internal disk. If that is
   not what you want, power the machine off now — before the countdown ends.
   (Jenny Jump, 2026-10-20: the countdown used to be ten seconds behind a
   title that named a product rather than an action.)
4. **What you'll see next:** the installer runs by itself, asking nothing.
   After a few minutes **the machine turns itself off**. That is your signal.

   ⚠ **It can sit on "creating LVs" for a long time** when the disk held an
   earlier install. That is the installer working, not a hang. **Do not
   switch the machine off** — wait at least 30 minutes. Cutting power there
   only makes you start again (AC0G-ND, 2026-10-05: the first attempt was
   switched off at this step; the second, left alone, finished).
5. **REMOVE THE STICK, then power the machine back on.** (Some machines
   always boot USB first and would install again in a loop — and the entry
   above erases the disk, so a stick left in such a machine can reinstall
   over a working station.)

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

**Remote access comes up by itself.** The wizard asks nothing about it: every
station registers with the fleet gateway and opens a tunnel, so that your fleet
admin can support it. Registering sends two things: the station's name and the
host's public key. You hold the switch, in the decoder VM (§10 says how to log
in):

```
smd remote off        # turn remote access off; it stays off across reboots
smd remote on         # turn it on again
smd remote status     # show the state
```

(If the summary's `RAC:` line says `wanted on, not up`, don't worry: remote
access touches neither the radio nor any upload. If its second line says the
station has not registered yet, no gateway has answered, and the host tries
again every ten minutes. The other cases are in
[remote access](https://github.com/HamSCI/sigmond/blob/main/docs/operator/remote-access.md#7-if-remote-access-does-not-come-up).
In rare cases the line reads `FAILED: …` instead. Such a line names its own next
step.)

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

⚠ **After this the keyboard no longer types into the host itself. That is normal
and correct.** The USB ports now belong to the decoder VM, so a keyboard plugged
into the station types into the VM. The station still carries that typing to a
login on the host, and the panel says so on its second line:
`Press Enter here for a hypervisor login; typing does not echo, which is normal.`
Press Enter, then
type the host's root password when the screen asks for it. Nothing shows while
you type the password. With that login on the host you can type `sigmond-check`
(§9), and `sigmond-setup --rac-off`, `sigmond-setup --rac-on` and
`sigmond-setup --pair-vm` (§10 says what they do). For everything else, use the
station from another computer.

After that login, a menu opens on the screen. Use the arrow keys and Enter to
check the station (`sigmond-check`), change its settings (`sigmond-setup --reconfigure`),
turn remote access off or on, or test the gateway and DNS over IPv4 and IPv6. Choose
**Shell**, or press Esc, for an ordinary command prompt. The same menu opens after a
root login at the host's own screen. An SSH login from another computer gets the plain
prompt.

The panel lists every address and login;
disconnect the monitor and keyboard whenever you like.

---

## 9. Fifteen minutes later — check it's alive

At the station's keyboard, press Enter and log in to the host, as §8 describes.  Then
type one command:

```
sigmond-check
```

It takes about fifteen seconds.  It prints one line for each part of the station and
ends with a verdict:

```
 ok    PSK            214 FT8 and 31 FT4 spots in the last 15 min
 ok    WSPR           48 spots in the last 10 min, on 6 bands
 FAIL  magnetometer   frozen: 0.00 C, no change in 60 s.
                      Fix: sigmond-vm sudo systemctl restart mag-recorder
 wait  GRAPE          first files due in about 7 min (hf-timestd started 4 min ago)
 ok    storage        /var/lib has 61 % free
 wait  uploads        off, new station: check the lines above, then run: sigmond-vm smd sink upload
 --    meteor scatter not on this station
 ok    receiver page  IPv4 http://192.168.1.50:8081   IPv6 http://[2601:db8::50]:8081
 ok    station pages  IPv4 http://192.168.1.50:8000   IPv6 http://[2601:db8::50]:8000
 ok    magnetometer page  IPv4 http://192.168.1.50:8082   IPv6 http://[2601:db8::50]:8082
FAIL  (1 failing, 2 waiting)
```

The word at the start of a line tells you how that part stands:

| Word | Meaning |
|---|---|
| `ok` | It works. |
| `wait` | Not yet.  A new station shows this for a while; the line usually says how long to wait. |
| `FAIL` | It does not work.  The line says what to do, or whom to tell. |
| `--` | This station does not run that part, and the verdict leaves it out.  A station without a magnetometer shows `--` on the magnetometer line. |

Right after the install the station may still bring itself up.  Then the first line
reads `wait  bring-up  still running (started 12 min ago)`.  A part that bring-up has
installed but not started yet shows `wait`; a part it has not installed yet shows `--`.
Type `sigmond-check` again in ten minutes.

If the first line reads `FAIL  bring-up  ran without the radio`, no SDR stood on the USB
bus when bring-up ran.  Plug the SDR in; bring-up finishes by itself.  Until then the
radio parts show `wait` and offer no fix.  Any other `FAIL  bring-up` line means the
bring-up failed: send the whole output to your fleet admin.

The last line gives the verdict.  `PASS` means every part works.  `WAIT` means some part
has not started yet: wait the time its line names, then type `sigmond-check` again.
`FAIL` means some part does not work.  Do what its line says.  A fix stands on its own
line under it, after the word `Fix:`; type it exactly as printed.  When a `FAIL` line
names no fix, send the whole output to your fleet admin.

A quiet band can look like a fault.  So when a `FAIL` line says no spots arrived, it asks
you to check the antenna and its cable before anything else.  When the radio itself has
stopped, the line says so instead and asks you to tell your fleet admin.

A new station sends nothing yet.  It starts with its site sink switch at `off`: it
records and decodes, but sends no spots or data to wsprnet, pskreporter.info,
wsprdaemon.org or PSWS.  So the uploads line shows `wait` and says `new station`.

When every other line shows `ok` or `--`, turn the uploads on:

```
sigmond-vm smd sink upload
```

Then type `sigmond-check` again.  The uploads line now shows `wait`, and the verdict
reads `WAIT`, until the first delivery arrives, within 30 minutes.  After that the line
shows `ok`.  If it shows `FAIL` because nothing went out in 30 minutes, send the whole
output to your fleet admin.  An uploads line that shows `FAIL` with `off` or `hold` and
some other reason means someone set the switch on purpose.  Leave it alone and ask your
fleet admin.

When you run `smd sink upload`, the station sends the GRAPE and magnetometer packages
for today and yesterday (UTC), even if it built them while the switch read off.  Older
packages stay on the station, and nothing else recorded before the switch ships.  The
station packs each UTC day's data after that day ends, between 01:00 and about 05:00
UTC.  If you turn the uploads on before that day's packing finishes, the package goes
out later, once the station builds it.  While a packing job runs, `smd sink upload` refuses,
names the job, and asks you to try again when it ends.  About fifteen minutes after,
search your reporter ID at wsprnet.org (Database) and your callsign at pskreporter.info.

If you like, open the pages from another computer on the same network.  `sigmond-check`
printed their addresses, for example `http://192.168.1.50:8081` over IPv4 or
`http://[2601:db8::50]:8081` over IPv6.  A browser needs the square brackets around an
IPv6 address.  The receiver page shows a waterfall with signals; the station pages show
the callsign, the grid, and the timing and GRAPE pages.  The pages answer only computers
on the station's own network, over IPv4 and IPv6 alike.  A computer elsewhere on the
internet, or a VPN peer of the host, gets no answer, even when it can reach the host's
address or route to the decoder VM's private one.  For IPv4, "own network" means the private ranges (10.x, 172.16-31.x, 192.168.x).
If your LAN uses public addresses, list its prefix, for example `129.24.8.0/22`, as one line
in `/etc/sigmond/vm4relay-allow.conf` on the host (owned by root, writable by root only).
`sigmond-vm4relay status` shows the list and where each entry came from.
If your site numbers its computers by DHCPv6 (one /128 address each), the host cannot tell
which network it sits on.  Add your LAN's prefix, for example `2601:db8:1:2::/64`, as one
line in `/etc/sigmond/vm6proxy-allow.conf` on the host (owned by root, writable by root
only).  The relay reads it within 15 minutes; `sigmond-vm6proxy status` shows the result.

From another computer you can also ask the decoder VM alone.  This prints the VM's own lines,
without the host's checks of the addresses people browse to:

```
ssh -p 2222 sigmond@<host address> smd check
```

---

## 10. Logins — and change the password

**One password unlocks the whole station.** It starts as **`hamsci-sigmond`**.
The wizard copies the host's root password to the decoder VM's `sigmond`,
`hamsci` and `root` accounts, so they all take the same one. Root login over
SSH stays off on the VM.

| Where | How |
|---|---|
| Proxmox host (the machine itself) | `ssh root@<host address>` or browse `https://<host address>:8006` |
| Decoder VM (the radio) | `ssh -p 2222 sigmond@<host address>` (relayed by the host; also `hamsci@`). On a station with the old layout, where the VM sits on your own network with no private link to the host: `ssh sigmond@<VM address>` |

Change it: run `passwd` on the host, and in the VM.

**PSWS stations:** the VM's login banner shows this machine's public upload key.
Paste it into the PSWS portal for your station
(https://pswsnetwork.eng.ua.edu/), then run `smd psws verify`. Until then the
station keeps recording locally. Packages built after you run `smd sink upload`
wait on the station and ship once the key verifies. Packages built before that
command stay on the station in a held folder and never ship (§9). **One key
serves the whole machine:** if it uploads for more than one station, register
the same key on each. (If you restored keys in §4, this is already done.)

**Remote access starts on, and you can turn it off.** Log in to the decoder VM
and run `smd remote off`. `smd remote on` turns it on again, and
`smd remote status` shows the state. Off stops the tunnel your fleet admin uses
and changes nothing else: every upload keeps running, and off stays off across
reboots. The console panel shows which state holds. More:
[remote access](https://github.com/HamSCI/sigmond/blob/main/docs/operator/remote-access.md).

**The host works the same switch.** With a login on the host,
`sigmond-setup --rac-off` and `sigmond-setup --rac-on` do what `smd remote off`
and `smd remote on` do. `smd remote` itself works once the VM and the host have
paired, and the wizard pairs them at install. Its summary then carries a
`Switch:` line that begins `paired:`. If that line begins `NOT PAIRED`, the two
have not paired, or the host's last check of the pairing failed. The console
panel then names the host's own switch as a line to type on another computer:
`ssh root@<host address> 'sigmond-setup --rac-off'` (or `--rac-on`). Once the
host holds its switch files, its private link to the VM and a readable sshd key,
it tries the pairing again four minutes after every boot, every six hours after
that, and whenever its sshd key changes.
`sigmond-setup --pair-vm`, typed with a login on the host, tries it at once.
More: [remote access §8](https://github.com/HamSCI/sigmond/blob/main/docs/operator/remote-access.md#8-a-station-installed-before-v371).

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
| Remote access says `wanted on, not up` | The radio and every upload keep working. In the VM, `smd remote status` names the case on its second line. "has not registered yet" needs nothing from you: the host tries again every ten minutes. For the others, see [remote access](https://github.com/HamSCI/sigmond/blob/main/docs/operator/remote-access.md#7-if-remote-access-does-not-come-up) |
| You want remote access off | In the VM: `smd remote off`. `smd remote on` turns it on again |
| The panel prints `ssh root@<host address> 'sigmond-setup --rac-off'` where this guide says `smd remote off` | The VM and the host have not paired, or the host's last check of the pairing failed (§10). Type the panel's line from another computer; it works the same switch |
| The panel prints `bring-up ran WITHOUT the radio` | No SDR stood on the USB bus when bring-up ran. Plug the SDR in. Bring-up finishes by itself, and nothing else needs your hands |
| The panel prints `the decoder VM's guest agent does not answer` | The host cannot ask the decoder VM anything for the moment. The radio and the uploads go on. The panel tries a reset at every refresh, every five minutes. When the line stays for more than ten minutes while the VM runs, tell your fleet admin |
| No spots after 30 minutes | Expected on a new station until you turn the uploads on (§9). At the host's console, type `sigmond-check`. If the uploads line says `new station`, check the other lines as §9 describes, then type `sigmond-vm smd sink upload`. If it shows `off` or `hold` with any other reason, ask your fleet admin. If the PSK or WSPR line shows `FAIL` with no fix, do what it says: it names the antenna and its cable, or a radio that has stopped. Then send the whole output to your fleet admin |
| Anything else | Your fleet admin can log in through remote access and fix it — just ask. If you turned remote access off, run `smd remote on` in the VM first |

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
   starts that way. Check reception there with `sigmond-check` (§9): every
   line but uploads should show `ok` or `--`. No data leaves the station.
2. At the destination, log into the **Proxmox host** (`ssh root@<host address>`,
   or the console before the USB controllers were handed to the VM) and run
   `sigmond-setup --reconfigure`.
3. Answer the questions again. The wizard asks for your reporter ID and PSWS
   ids afresh, and pressing Enter at the PSWS station ID skips PSWS, so have
   them at hand. Type the **new grid square**. A station whose GPSDO has a fix
   fills in the grid by itself, and may already have moved the grid; check it
   on the review screen. The wizard keeps your remote-access number, the
   remote-access switch and the site sink switch as they were.  On a station
   installed before v3.84 it also turns the old status heartbeat off.
4. Log in to the decoder VM and check the identity:
   `grep -E 'reporter_id|callsign|grid' /etc/sigmond/site-profile.toml`.
   (The station pages keep the grid from the first install.) Then run
   `smd sink status`. If it says `site sink: upload`, someone raised the
   switch earlier; verify on wsprnet after about 15 minutes. If it gives any
   reason but `new station: …`, or says `fill` or `hold (legacy)`, someone
   set the switch on purpose; ask your fleet admin. If it still gives the reason
   `new station: …`, run `smd sink upload` (§9 explains the packing window),
   then verify on wsprnet after about 15 minutes.
