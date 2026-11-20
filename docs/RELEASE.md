# Release process

The release lives in sigmond now. The process, the rungs, the bless
step and every release note sit in the sigmond repo:

- Process: [`release/RELEASE.md`](https://github.com/HamSCI/sigmond/blob/main/release/RELEASE.md)
- History: [`CHANGELOG.md`](https://github.com/HamSCI/sigmond/blob/main/CHANGELOG.md)

This repo, `HamSCI/sigmond-proxmox`, builds and tests the image. The
build script (`build-usb-v3.sh`) installs the component list from
sigmond's `release/components.toml`. The nested, update and bare-metal
tests run here and leave their records for sigmond's bless step to read.
Blessing itself happens from sigmond's `release/bless-release.sh`.
