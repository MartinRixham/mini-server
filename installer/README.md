# Two-distro installer stick

One Ventoy USB stick that installs the mini server from scratch:

| SSD | Boots | Holds |
|---|---|---|
| drive 1 | AlmaLinux (Server with GUI) | ESP, `/boot` (ext4), half of the btrfs raid1 pool |
| drive 2 | Bazzite | ESP, `/boot` (ext4), half of the btrfs raid1 pool |

Both root filesystems are subvolumes of one btrfs **raid1** pool (label `minipool`)
spanning both drives: `@alma`, `@alma_home`, `@bazzite`.

Each distro also gets a **"… - one SSD missing (degraded)"** boot entry, so it
can still boot when the other drive dies. See
[If an SSD dies](../README.md#if-an-ssd-dies). It is made of three parts, all
set up by `kickstart/degraded-boot.sh`, which `build-usb.sh` pastes into both
kickstarts' `%post`:
- `/boot/grub2/custom.cfg` holds the entry: a copy of the default entry with
  `,degraded` added to `rootflags=`. `minipool-degraded-boot.service` rewrites it
  at every boot and shutdown, so it follows kernel and ostree updates. Both
  Alma's `grub.cfg` and Fedora's static one source `custom.cfg`.
- `rootflags=degraded` on its own isn't enough. systemd's `64-btrfs.rules`
  never marks a pool with a missing member as ready, so the root mount waits
  until it times out. `/etc/udev/rules.d/65-minipool-degraded.rules` marks it
  ready, but only on a degraded boot.
- That rule must also be in the initramfs. Alma adds it with a `dracut.conf.d`
  file. Bazzite's initramfs comes prebuilt in the image, so the first-boot
  service adds the rule with `rpm-ostree initramfs-etc` and reboots one more
  time. That overlay is the one way Bazzite differs from a fresh ISO install.

The same fragment installs `minipool-rebuild` (`/etc/minipool/rebuild`, linked
into `/usr/local/bin` by a `tmpfiles.d` entry, because on ostree `/usr/local`
is in `/var`). It runs step 2 of "If an SSD dies". When drive 1 died, that
includes rebuilding AlmaLinux's ESP and `/boot` from Bazzite, in a chroot into
`@alma`.
`minipool-degraded-notice.service` writes a notice to `/run/motd.d` and
`/run/issue.d` at boot while the pool is missing a member or isn't all RAID1.

Each step is the distro's own graphical installer. A kickstart fills in the disk
layout and software, and leaves you to fill in language, keyboard, **network/WiFi**,
hostname, timezone, root password and user account.

Bazzite can't be installed reliably from a kickstart
([ublue-os/bazzite#3418](https://github.com/ublue-os/bazzite/issues/3418)), so
step 2 installs Fedora Silverblue and a first-boot service rebases it to Bazzite.

## Build the stick (any Linux machine, x86 or ARM)

1. Edit `config.env` if needed. The settings are the Bazzite variant (e.g. `bazzite-nvidia`),
   the Fedora version (keep it equal to Bazzite's base) and, optionally, the serial number
   for each drive. Get those from `lsblk -dno NAME,SERIAL` on the server. Without them,
   Alma goes on the first disk in kernel name order (`nvme0n1`).
2. Run `./build-usb.sh --device /dev/sdX` (needs sudo; needs ~3 GB on the stick).
   It downloads Ventoy and both ISOs to `.cache/` and checks their sha256 sums.
   The first run erases the stick. Later runs only refresh the files.

## Install

The server's firmware boot menu is usually F7, F11 or F12. If Secure Boot is on, Ventoy
asks you to enrol its key once (follow its on-screen "Enroll key" steps), or you can
turn Secure Boot off for the install.

### Step 1: AlmaLinux (erases both SSDs)
1. Boot the stick, pick **Step 1: AlmaLinux…**, and leave the auto-install template selected.
2. Fill in the flagged items on the installer's summary screen. Connect WiFi under
   **Network & Host Name** first, because packages download from the internet.
3. **Begin Installation** is the point of no return. Before that nothing is written, and the
   disk layout is fixed by the kickstart. Reboot when it finishes.

### Step 2: Silverblue → Bazzite (drive 2, keeps Alma)
1. Boot the stick again, pick **Step 2: Silverblue -> Bazzite**.
2. Same again: WiFi, user, etc. Then **Begin Installation**. It adds Bazzite's
   ESP and `/boot` in the space left on drive 2 and a new `@bazzite` subvolume.
   Nothing existing is reformatted. The installer refuses to run if Alma's pool
   isn't there or Bazzite already is.
3. Reboot into the new system (from drive 2's boot entry), log in and leave it running.
   `rebase-to-bazzite.service` downloads Bazzite (~8 GB), reboots itself, does the second
   (signed-image) rebase and reboots again. Watch it with
   `journalctl -fu rebase-to-bazzite`. If the network is down it retries every minute.
   When it's done, it drops the rollback deployment and deletes itself, so
   `rpm-ostree status` shows a single `ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:…` deployment.

Choose which distro boots using the firmware boot menu, or set the default with
`efibootmgr --bootorder`.

## Rehearse in a VM first

`./test-vm.sh` runs the same flow in QEMU with two blank 80 GB NVMe disks. The comment
at the top of the script explains how to build a stick image without a real USB stick.
Use an x86 machine with KVM; emulated on ARM it's very slow.

## Tests and CI

`tests/test-kickstarts.sh` runs offline. It runs each kickstart's `%pre` against
fake disks and checks the partitioning it generates, or that it refuses when it
should. It also shellchecks every script. It needs only bash and shellcheck.

`.github/workflows/installer.yml` runs on every push, every PR and once a week:
- **test** runs the script above, then validates both full kickstarts with
  `ksvalidator`. Each is checked in its own distro's container: AlmaLinux ships a
  pykickstart that allows btrfs, while upstream's RHEL10 profile rejects it.
- **build** builds a real stick image on a loop device with `build-usb.sh`
  (downloads Ventoy and both ISOs and verifies their checksums), then checks what
  ended up on the stick. The weekly run catches upstream URL or ISO changes.

- **vm-install** runs `tests/vm-install.sh`. It does the whole install unattended
  in QEMU/KVM with two NVMe disks: AlmaLinux, then Silverblue, then the first-boot
  rebase to signed Bazzite. It boots each installed system and checks it over SSH:
  the partitions, the raid1 pool across both drives, the subvolumes, which drive
  each `/boot` is on, and that Alma still boots after Bazzite is installed. Then
  each drive "dies" in turn, on throwaway qcow2 overlays of the installed disks.
  The other distro is booted from its degraded entry with a blank disk in the
  dead one's place. It checks the login notice, then rebuilds the pool onto the
  blank disk with `minipool-rebuild`, which has to pick that disk itself. When
  drive 1 dies, AlmaLinux is then booted from the new disk and checked like a
  fresh install. Finally it boots normally again and checks that every chunk
  is RAID1. It takes 1.5-2.5 hours. Logs and failure screenshots are uploaded as the `vm-install-logs`
  artifact.

  To run unattended, the ISO kernels are booted directly (not through Ventoy) and
  each kickstart gets a CI add-on in place of the GUI questions. The add-on sets
  text mode, language, keyboard, timezone, a throwaway root password, an SSH key and
  poweroff. Disk serials are pinned. On an x86 machine with KVM you can run it
  yourself: `tests/vm-install.sh all`.
- **release** runs on `main` (not PRs) after both build and vm-install pass. It replaces
  the rolling [`usb-latest`](https://github.com/martinrixham/mini-server/releases/tag/usb-latest)
  release with the xz-compressed stick image built from `config.env`, its `SHA256SUMS`,
  and the `dd` command to write it. You can download that instead of running `build-usb.sh`,
  but the disk serials in it are the ones committed in `config.env`.

## Known risks / unverified

- **Step 2's partitioning is the least-tested part.** Anaconda has to add a subvolume
  to a raid1 btrfs pool that a different installer created. The kickstart syntax
  is valid, but run the VM rehearsal before trusting it.
- **A rebased Bazzite isn't byte-identical to an ISO install.** Things the Bazzite ISO
  sets up at install time (e.g. preinstalled Flatpaks) may need doing by hand.
  Bazzite's `ujust` commands cover most of it.
- **If one SSD dies, only the other drive's distro boots, and only from its degraded
  entry.** The dead drive held the other distro's ESP and `/boot`. CI tests booting
  degraded and rebuilding the pool. Rebuilding the lost distro's boot partitions
  (step 3 of [If an SSD dies](../README.md#if-an-ssd-dies)) is untested.
