# Operator keys

Every `*.pub` in this directory is concatenated into the operator key set and
installed on **both** planes of every station built from the resulting image:

| Plane            | File                                | Access it grants |
|------------------|-------------------------------------|------------------|
| PM host (Proxmox)| `/root/.ssh/authorized_keys`        | root, direct     |
| Decoder VM       | `/home/hamsci/.ssh/authorized_keys` | `hamsci`, NOPASSWD sudo → root |

So a key in this directory is **root on every station built from this image**.

## Policy — rob, 2026-09-22: PERSONAL KEYS ONLY

This is the fallback door for when the guest agent is down and the console is
400 miles away. It is not a general access-grant mechanism.

- rob's own machines: yes.
- a role or shared key (wsprdaemon@WD0 was offered and DECLINED): no.
  Anyone holding that private key would get root on the whole fleet, and a
  shared key cannot be revoked for one holder.
- another operator: their OWN key, in their OWN file, so it can be attributed
  and removed independently.

## Adding or removing an operator

Add `operators/<name>.pub` — one person per file, their own key(s), a comment
line naming them. Remove with `git rm`. The git log then says who was granted
access, by whom, and when; a single shared file could never answer that.

The build **counts keys, not files**: it refuses to build a keyless image
regardless of which files exist (override: `VMKEYLESS_OK=1`).

## ⚠ Rotation is image-scoped

Editing this directory changes FUTURE images only. Stations already in the
field keep whatever keys their image shipped with, so a new operator cannot
reach an existing station until it is reflashed or their key is added by hand.
A post-install path (`smd admin operator-key add`) would close that and does
not exist yet.

## ⚠ Keep the build rig in sync

2026-09-22: the build rig (`root@192.168.1.182:/root/appliance/v3`) carried a
DIFFERENT `rob.pub` holding only `rob@robinett.us`, and it is not a git
checkout, so it never saw the repo's copy. Every decoder VM built there —
v3.48 through v3.50, AI6VN included — answered to that key ALONE. It looked
like the VMs were keyless; they were not, they had a key nobody was trying.
Diverge the rig from this directory again and the next lockout is the same
lockout.
