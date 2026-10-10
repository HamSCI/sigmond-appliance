# offline-debs — packages the media must carry

A greenfield **IPv6-only** install cannot use apt. The chicken-and-egg is exact:

- reaching the IPv4 package mirrors needs the CLAT,
- the CLAT is `clatd`,
- installing `clatd` needs apt.

Likewise a host with **no Ethernet** cannot install `wpasupplicant` to bring up
the Wi-Fi it would need to reach apt.

So these ship on the install media and are applied with `dpkg -i` before any
network is expected to work. About 7.5 MB in all — cheap insurance.

| package | why |
|---|---|
| `clatd` + `tayga` | 464XLAT: gives the host an IPv4 default route over a translating tun, so IPv4 *literals* work — which plain NAT64+DNS64 does not provide |
| `dnsmasq`, `dnsmasq-base` | the decoder VM is IPv4-only and cannot reach the site's IPv6 resolver; the PM serves it DNS over IPv4 |
| `ndisc6` | `rdisc6`, to read RDNSS out of a Router Advertisement. Nothing on Proxmox consumes RDNSS, so without this a v6-only station has **no resolver at all** |
| `rdnssd` | the daemon form of the same, for ongoing RA changes |
| `wpasupplicant`, `iw` | Wi-Fi association and scanning. **Neither is in stock PVE** |
| `btop`, `tmux` | operator tooling on the PM — rob works from tmux and reads per-core load in btop, and a station on an IPv6-only site cannot apt them in. **Neither is in stock PVE**; every dependency of both already is |
| `sudo` | the remote-access pairing: one account on the PM may run one script as root, by one sudoers line (sigmond `tasks/plan-remote-access.md` section 2). The wizard pairs at install, before any network is assumed. **Not in stock PVE**; every dependency of it already is |
| the rest | dependency closure of the above that stock PVE lacks |

`sudo` ships as `sudo_1.9.16p2-3+deb13u2_amd64.deb` (Debian 13 trixie, amd64, from
`deb.debian.org`, fetched with `apt-get download sudo` on 2026-10-09), sha256
`4f926f8f0704575158a90135713977f98f7d50d185969d9a8a405cdce5e3e50c`.  Its `Depends` are
`libapparmor1`, `libaudit1`, `libc6`, `libpam0g`, `libselinux1`, `libssl3t64`, `zlib1g`
and `libpam-modules`; its `Pre-Depends` is `init-system-helpers`.  That every one of them
stands on a stock PVE 9 host was not checked when the file was fetched, since the fetching
box is no PVE host.  The nested rig's remote-access check 1 fails unless dpkg reports sudo
`install ok installed` on a nest built from this media.

## Refreshing

Computed against a real PVE host, not guessed:

```bash
WANT="clatd tayga dnsmasq dnsmasq-base rdnssd ndisc6 wpasupplicant iw btop tmux sudo"
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
    --no-breaks --no-replaces --no-enhances $WANT | grep '^[a-z0-9]' | sort -u
# keep the ones a stock PVE does not already have, then:
apt-get download <that list>
```

⛔ **Over-collecting is safe only for LEAF packages.**  The btop/tmux closure
(2026-09-29) was 11 packages, nine of which were `libc6`, `libsystemd0`,
`libstdc++6` and friends — all already present on a fresh PVE.  Shipping those
would put core libraries in a payload that is applied with `dpkg -i` on a
running station, where a version mismatch is far worse than a missing tool.
Checked each against a freshly installed v3.56 PM: only `btop` and `tmux` were
absent, so only those two ship.

Over-collecting is safe: `dpkg -i` skips what is already installed. Under-collecting
is not — it fails on the one station that cannot reach a mirror to recover.

⛔ **Compute the closure on a host that does NOT already have these packages.**
The first version of this payload was 17 packages and was missing
`libnl-genl-3-200` and `libpcsclite1`, because it was computed on a host where
`wpasupplicant` had already been installed via apt — so the dependencies apt had
pulled in were invisible to the "what is missing here" filter. The result was a
`wpasupplicant` left `install ok unpacked`, which is **worse than not shipping it
at all**: the unpack installs `/etc/network/if-{pre-,}up.d/wpasupplicant` while
their targets are still `.dpkg-new`, and ifupdown2 then fails EVERY interface
bring-up with ENOENT. On the nested IPv6 test that took `vmbr1` down and the
decoder VM never imported.

`dpkg --simulate -i *.deb` does NOT catch this — it reported no dependency
problems for the incomplete set. The check that matters is that no package is
left in state `unpacked` after `dpkg --configure -a`, which firstboot now
asserts and reports.

⚠ These pin to the Debian 13 / PVE 9 versions current at build time. Refresh them
when the base moves, or `dpkg -i` will fail on a libc mismatch.
