# sigmond-appliance

Build pipeline for the turnkey Sigmond appliance USB image:
a self-contained stick that bare-metal-installs Proxmox VE 9.1 unattended,
auto-imports an identity-clean Sigmond decoder VM (golden template built with
`smd admin capture-prep`, verified by the capture readiness gate), and runs a
first-boot console wizard that prompts for the ONLY per-site facts:
reporter ID, grid square, optional antenna description, optional RAC
credentials (host-side tunnel: host SSH + Proxmox GUI).

Validated end-to-end 2026-07-02 in a nested qemu/OVMF rig (4-phase test) and
on real hardware. Operator instructions: see QUICKSTART.txt (also shipped on
the stick's payload).

## Pipeline (run on the build host, e.g. B3)
1. `build-golden-vm.sh`     — cloud-image VM, clone HamSCI repos, `smd install`,
                              `complete-profile.sh` (full dasi2 set),
                              `smd admin capture-prep --yes` + capture gate,
                              compact to the template qcow2
2. `build-usb-v2.sh [--release]` — prepare-iso (answer.toml.template +
                              firstboot-v2.sh) + ext4 payload (template,
                              sigmond-wizard.sh, sigmond-rac payload,
                              QUICKSTART.txt) appended at the aligned ISO
                              offset. `--release` strips the test ssh key.
                              Output name is date+time versioned.
3. `test-nested-v2.sh [A|B|C|D]` — 4-phase nested qemu/OVMF validation
                              (install / armed importer / hotplug import /
                              wizard drive). `qmp-type.sh` = blind console
                              typing via QMP for debugging.

## Hard-won packaging rules (violate at your peril)
- The ISO bytes must stay PRISTINE; the payload is appended at the
  1 MiB-aligned iso9660 volume-size offset. Adding a GPT partition for the
  payload silently breaks UEFI auto-install.
- `reboot-mode = "power-off"` is deliberate: firmwares that always boot USB
  first would otherwise reinstall in a loop. Power-off = remove-the-stick cue.
- The decoder VM import is udev-hotplug driven on the RUNNING host — no
  USB-present boot is ever required.
- In the nested test rig, keep the qemu PCI topology IDENTICAL between the
  install and later boots (xhci controller always present, declared before
  usb-storage) or the NIC renames and PVE's bridge config breaks.
