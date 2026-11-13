# mini-server
Server setup for a mini PC: AlmaLinux on drive 1 and Bazzite on drive 2. Both
root filesystems sit on one btrfs raid1 pool that spans the two SSDs. See
[installer/README.md](installer/README.md) for the full details.

## Install

### 1. Make the USB stick

You need a USB stick of at least 8 GB. Writing the image erases everything on it.

Download the prebuilt image from the rolling
[`usb-latest`](https://github.com/martinrixham/mini-server/releases/tag/usb-latest)
release and write it to the stick:

```bash
gh release download usb-latest -R martinrixham/mini-server -D mini-server-usb
cd mini-server-usb
sha256sum -c SHA256SUMS

lsblk -o NAME,SIZE,MODEL,TRAN   # find the stick, e.g. sdX
cat mini-server-usb.img.xz.part* | xz -dc | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

The image is split into `.part0`, `.part1`, … because each GitHub release file
can be at most 2 GiB. The command above joins the parts and decompresses them
as it writes, so you don't need to join them first. If the release has a
single `mini-server-usb.img.xz`, use
`xz -dc mini-server-usb.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`.
Write to the whole device (`/dev/sdX`), not to a partition (`/dev/sdX1`).

The release uses the defaults in [`installer/config.env`](installer/config.env).
To change the Bazzite variant, the Fedora version or which drive gets which
distro, edit that file and build the stick yourself with
[`installer/build-usb.sh`](installer/README.md#build-the-stick-any-linux-machine-x86-or-arm).

### 2. Install AlmaLinux (erases both SSDs)

1. Boot the server from the stick. The firmware boot menu is usually F7, F11 or
   F12. If Secure Boot is on, enrol Ventoy's key once when it asks.
2. Pick **Step 1: AlmaLinux…** and keep the auto-install template.
3. On the summary screen, connect WiFi under **Network & Host Name** first, then
   fill in the other flagged items (user, root password, …).
4. Click **Begin Installation**. Nothing is written to disk before this point.
   Reboot when it finishes.

### 3. Install Bazzite (drive 2, keeps Alma)

1. Boot the stick again and pick **Step 2: Silverblue -> Bazzite**.
2. Fill in WiFi, user and so on as before, then click **Begin Installation**.
3. Reboot into the new system from drive 2's boot entry, log in and leave it
   running. A first-boot service rebases it to Bazzite. It downloads about 8 GB
   and reboots itself twice. Follow its progress with
   `journalctl -fu rebase-to-bazzite`. It's done when `rpm-ostree status` shows
   a single `ostree-image-signed:docker://ghcr.io/ublue-os/bazzite:…` deployment.

Choose which distro boots from the firmware boot menu, or set the default with
`efibootmgr --bootorder`.

## If an SSD dies

Neither system loses any files, because every subvolume has a copy on each SSD.
What you do lose is the dead drive's boot partitions. Alma's are on drive 1 and
Bazzite's are on drive 2, so the distro on the other drive keeps working:

| Dead drive | Still boots (degraded) | Needs its boot partitions rebuilt |
|---|---|---|
| drive 1 | Bazzite | AlmaLinux |
| drive 2 | AlmaLinux | Bazzite |

CI rehearses steps 1 and 2 below for each drive. Step 3 is untested.

### 1. Boot with one SSD missing

Put the new SSD in. It must be the same size as the old one or larger. You can
also leave the slot empty for now. Boot the surviving drive from the firmware
boot menu and pick **… - one SSD missing (degraded)** in GRUB. If the menu
flashes past or never shows, hold Shift or tap Esc while it starts.

The normal entry won't boot. It stops at an emergency shell, because a btrfs
raid1 pool with a member missing only mounts when asked to. The degraded entry
asks, and it is kept in step with kernel and Bazzite updates. Until step 2 is
done, everything is written to the one remaining SSD, so don't wait long.

On a headless server you can pick the degraded entry ahead of time, for the
next boot only. Run this before you shut down to swap a failing SSD:

```bash
sudo unshare -m sh -c 'test -w /boot/grub2 || mount -o remount,rw /boot
    grub2-editenv - set minipool_boot_once=degraded'
```

Don't put the dead SSD back in later. Its copy of the pool is out of date.

### 2. Rebuild the pool onto the new SSD

Run these as root on the surviving distro. `POOL` is `/` on Alma and `/var` on
Bazzite, because Bazzite's `/` is not the pool itself.

```bash
POOL=/                                # /var on Bazzite
lsblk -o NAME,SIZE,SERIAL,FSTYPE      # the new SSD is the one with no partitions
NEW=/dev/nvme1n1                      # the new SSD. Check twice: this erases it
btrfs filesystem show $POOL           # one devid says "missing"
DEVID=$(btrfs filesystem show $POOL | awk '$1=="devid" && tolower($0) ~ /missing/ {print $2}')
MEMBER=$(btrfs filesystem show $POOL | awk '$1=="devid" && $NF ~ "^/dev/" {print $NF}')
MIB=$(( ($(blockdev --getsize64 $MEMBER) + 1048575) / 1048576 ))
```

Partition the new SSD like the one it replaces:

```bash
# Drive 2 died (you're on Alma): the pool member, with the rest left free for Bazzite
echo "size=${MIB}MiB, type=linux" | sfdisk --label gpt $NEW
PART=${NEW}p1

# Drive 1 died (you're on Bazzite): ESP, /boot, pool member
printf 'size=600MiB, type=uefi\nsize=2048MiB, type=linux\nsize=%sMiB, type=linux\n' $MIB | sfdisk --label gpt $NEW
PART=${NEW}p3
```

Then copy the pool onto it:

```bash
btrfs replace start -B $DEVID $PART $POOL     # copies everything onto the new SSD
btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft $POOL   # makes what was written while degraded raid1 again
btrfs scrub start -B $POOL                    # checks every copy
btrfs filesystem df $POOL                     # Data, Metadata and System should all say RAID1
```

Reboot. The surviving distro now boots normally from its usual entry.

### 3. Get the other distro booting again

This step is untested. The pool is whole again, but the dead drive's ESP and
`/boot` are gone.

**Bazzite (drive 2 died): reinstall it with Step 2 of the installer.** Its
system is an image, so the only thing worth keeping is the home folders. Get
them out from Alma first, then remove the old subvolume, since Step 2 creates a
new one:

```bash
mount -o subvol=/ LABEL=minipool /mnt
cp -a /mnt/@bazzite/ostree/deploy/*/var/home /root/bazzite-home   # if you want them
btrfs subvolume delete --recursive /mnt/@bazzite
umount /mnt
```

If `installer/config.env` pins disk serials, set `BAZZITE_DISK_SERIAL` to the
new SSD's serial and rebuild the stick. Then follow "3. Install Bazzite" above.

**AlmaLinux (drive 1 died): rebuild its boot partitions from Bazzite.** This
chroots into `@alma` and reinstalls the bootloader and kernels. It needs the
network. Run it as root on Bazzite, with `NEW` set as in step 2:

```bash
mkfs.vfat -F 32 ${NEW}p1
mkfs.ext4 -q ${NEW}p2
A=/mnt/alma; mkdir -p $A
mount -o subvol=@alma LABEL=minipool $A
mount ${NEW}p2 $A/boot && mkdir -p $A/boot/efi && mount ${NEW}p1 $A/boot/efi
for d in dev proc sys run; do mount --rbind /$d $A/$d && mount --make-rslave $A/$d; done
cp --remove-destination -L /etc/resolv.conf $A/etc/resolv.conf
chroot $A env NEW=$NEW /bin/bash <<'EOF'
set -e
BOOT_UUID=$(blkid -s UUID -o value ${NEW}p2) ESP_UUID=$(blkid -s UUID -o value ${NEW}p1)
# point fstab at the new /boot and ESP
awk -v b="UUID=$BOOT_UUID" -v e="UUID=$ESP_UUID" '$2=="/boot" {$1=b} $2=="/boot/efi" {$1=e} {print}' \
    /etc/fstab > /etc/fstab.new && mv /etc/fstab.new /etc/fstab
dnf -y reinstall shim-x64 grub2-efi-x64 grub2-common grub2-tools grub2-tools-minimal
for k in /lib/modules/*/vmlinuz; do v=${k%/vmlinuz}; kernel-install add "${v##*/}" "$k"; done
cat > /boot/efi/EFI/almalinux/grub.cfg <<STUB
search --no-floppy --fs-uuid --set=dev $BOOT_UUID
set prefix=(\$dev)/grub2
export \$prefix
configfile \$prefix/grub.cfg
STUB
grub2-editenv - create
grub2-mkconfig -o /boot/grub2/grub.cfg
grubby --set-default "$(ls /boot/vmlinuz-* | grep -v rescue | sort -V | tail -1)"
touch /.autorelabel          # files written from Bazzite get the right SELinux labels on first boot
EOF
efibootmgr -c -d $NEW -p 1 -L AlmaLinux -l '\EFI\almalinux\shimx64.efi'
umount -R $A
```

Alma's first boot after this relabels the filesystem and reboots once, which
takes a few minutes. Reinstalling from the stick also works, but Step 1 erases
both SSDs.
