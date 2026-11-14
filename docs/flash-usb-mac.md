# Flashing a Sigmond appliance image to a USB stick on a Mac

> **Audience:** operator
> **Status:** current
> **Verified against:** sigmond-appliance v3.91 on 2026-11-14 — a real v3.91 flash with Raspberry Pi Imager 2.0.x on macOS
> **Canonical for:** nothing; a one-page Mac handout. [../INSTALL.md](../INSTALL.md) wins where they disagree

You need a USB stick of **8 GB or larger**. Everything on the stick is erased.

## 1. Download the latest image

1. Open the release folder on Google Drive:
   <https://drive.google.com/drive/folders/1Eym7xsP_qVvbGOVmlXER73K3jx6J7dQs>
2. Find the newest `sigmond-appliance-vX.YY-YYYYMMDD-release.img`, the one with
   the highest version number, and its matching `.sha256` file. Download both.
   (Builds still in test are in the `pending` subfolder. Use the top level
   unless you were asked to test a pending build.)
3. The image is about 6 GB. Google says it can't scan a file that large for
   viruses: click **Download anyway**.
4. Optional but recommended: check the download. In Terminal, run these three
   lines:

   ```
   cd ~/Downloads
   shasum -a 256 sigmond-appliance-*-release.img
   cat sigmond-appliance-*-release.sha256
   ```

   The two long numbers must match.

## 2. Install Raspberry Pi Imager

Download it from <https://www.raspberrypi.com/software/> ("Download for
macOS"), open the `.dmg`, and drag **Raspberry Pi Imager** into Applications.
It writes any `.img` file, not only Raspberry Pi ones.

## 3. Write the image to the stick

1. Plug in the USB stick and open **Raspberry Pi Imager**. If macOS asks, allow
   it to access removable volumes.
2. **Choose Device:** pick **No filtering**. Any choice works, since this isn't
   a Pi image.
3. **Choose OS:** scroll to the bottom, pick **Use custom**, and select the
   `.img` you downloaded.
4. **Choose Storage:** pick your USB stick. Check the name and size carefully;
   never pick your Mac's own disk.
5. Click **Next**. Imager 2.x shows the **Customisation** step greyed out in
   its left-hand list and skips it, because a custom image can't be customised.
   That is expected. Older Imager versions instead ask whether to apply "OS
   customisation" settings: choose **No**. Either way the appliance sets itself
   up on first boot.
6. On the **Write image** summary, check that the OS line names the
   `sigmond-appliance` image and the Storage line names your stick, then click
   **Write**. Confirm the erase and enter your Mac password. Imager writes the
   stick, then verifies it (about 5 to 15 minutes).
7. When it says the write is finished ("Success"), remove the stick. If macOS
   complains the disk "is not readable", click **Eject**; that is normal for
   this image.

## 4. Install

Plug the stick into the station computer and boot from it. Leave other USB
drives unplugged, and set the firmware to boot from USB if needed. The
installer and the setup wizard take it from there; the install guide
([INSTALL.md](../INSTALL.md)) sits beside the image in the same Drive
folder.
