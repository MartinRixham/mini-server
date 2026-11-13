# Two-distro installer stick

One Ventoy USB stick that installs the mini server from scratch:

| SSD | Boots | Holds |
|---|---|---|
| drive 1 | AlmaLinux (Server with GUI) | ESP, `/boot` (ext4), half of the btrfs raid1 pool |
| drive 2 | Bazzite | ESP, `/boot` (ext4), half of the btrfs raid1 pool |

Both root filesystems are subvolumes of one btrfs **raid1** pool (label `minipool`)
spanning both drives: `@alma`, `@alma_home`, `@bazzite`.

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
   It's finished when `rpm-ostree status` shows `ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:…`.

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
  each `/boot` is on, and that Alma still boots after Bazzite is installed. It takes
  1-2 hours. Logs and failure screenshots are uploaded as the `vm-install-logs`
  artifact.

  To run unattended, the ISO kernels are booted directly (not through Ventoy) and
  each kickstart gets a CI add-on in place of the GUI questions. The add-on sets
  text mode, language, keyboard, timezone, a throwaway root password, an SSH key and
  poweroff. Disk serials are pinned. On an x86 machine with KVM you can run it
  yourself: `tests/vm-install.sh all`.

## Known risks / unverified

- **Step 2's partitioning is the least-tested part.** Anaconda has to add a subvolume
  to a raid1 btrfs pool that a different installer created. The kickstart syntax
  is valid, but run the VM rehearsal before trusting it.
- **A rebased Bazzite isn't byte-identical to an ISO install.** Things the Bazzite ISO
  sets up at install time (e.g. preinstalled Flatpaks) may need doing by hand.
  Bazzite's `ujust` commands cover most of it.
- **If one SSD dies, neither distro boots normally.** A degraded raid1 won't mount on its own.
  Add `rootflags=degraded` to the kernel command line once, then replace the drive with
  `btrfs replace` and rebalance.
