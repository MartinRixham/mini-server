# Fedora Silverblue onto drive 2, inside the existing "minipool" btrfs raid1,
# then rebased automatically to Bazzite on first boot.
#
# Run AFTER alma.ks. Nothing existing is reformatted: this adds Bazzite's ESP
# and /boot in the free space alma.ks left on drive 2, plus a new @bazzite
# subvolume in the pool.
#
# Partial kickstart: language, keyboard, network/WiFi, hostname, timezone,
# root password and user account are left for the graphical installer. The
# WiFi connection you set up there is copied into the installed system, which
# the first-boot rebase uses to download Bazzite (~8 GB).
#
# @...@ placeholders are filled in by build-usb.sh from config.env.

graphical

ostreecontainer --url=quay.io/fedora/fedora-silverblue:@FEDORA_VERSION@ --transport=registry --no-signature-verification

%include /tmp/part.ks

%pre --interpreter=/bin/bash --log=/tmp/ks-pre.log
set -euo pipefail

ALMA_SERIAL="@ALMA_DISK_SERIAL@"
BAZZITE_SERIAL="@BAZZITE_DISK_SERIAL@"
POOL_LABEL="minipool"
ESP_MIB=600
BOOT_MIB=2048

die() { echo "ERROR: $*" >&2; exit 1; }

internal_disks() {
    local d
    for d in /sys/block/*; do
        d=${d##*/}
        case $d in loop*|ram*|zram*|sr*|dm-*|md*|nbd*|fd*) continue ;; esac
        [[ $(cat /sys/block/"$d"/removable) == 0 ]] || continue
        [[ $(cat /sys/block/"$d"/size) -gt 0 ]] || continue
        [[ $(readlink -f /sys/block/"$d") == */usb* ]] && continue
        echo "$d"
    done | sort
}

disk_by_serial() {
    local d
    for d in $(internal_disks); do
        [[ $(lsblk -dno SERIAL "/dev/$d" | tr -d ' ') == "$1" ]] && { echo "$d"; return; }
    done
    die "no internal disk with serial '$1'"
}

mapfile -t DISKS < <(internal_disks)
echo "internal disks: ${DISKS[*]}"
[[ ${#DISKS[@]} -eq 2 ]] || die "expected exactly 2 internal disks, found ${#DISKS[@]}: ${DISKS[*]}"

POOL_DEVS=$(blkid -t LABEL="$POOL_LABEL" -o device | wc -l)
[[ $POOL_DEVS -eq 2 ]] || die "btrfs pool '$POOL_LABEL' not found on 2 devices (found $POOL_DEVS) - run the AlmaLinux install first"

if [[ -n $ALMA_SERIAL && -n $BAZZITE_SERIAL ]]; then
    D1=$(disk_by_serial "$ALMA_SERIAL")
    D2=$(disk_by_serial "$BAZZITE_SERIAL")
else
    # Drive 2 is the one alma.ks left without an EFI partition.
    D1="" D2=""
    for d in "${DISKS[@]}"; do
        if lsblk -nro PARTTYPE "/dev/$d" | grep -qi c12a7328-f81f-11d2-ba4b-00a0c93ec93b; then
            D1=$d
        else
            D2=$d
        fi
    done
    [[ -n $D1 && -n $D2 ]] || die "could not tell drives apart (need exactly one with an EFI partition)"
fi

if lsblk -nro PARTTYPE "/dev/$D2" | grep -qi c12a7328-f81f-11d2-ba4b-00a0c93ec93b; then
    die "$D2 already has an EFI partition - Bazzite looks installed already; refusing to continue"
fi

echo "Alma disk: $D1   Bazzite disk: $D2"

cat > /tmp/part.ks <<EOF
ignoredisk --only-use=$D1,$D2
bootloader --boot-drive=$D2
part /boot/efi --fstype=efi  --size=$ESP_MIB  --ondisk=$D2
part /boot     --fstype=ext4 --size=$BOOT_MIB --ondisk=$D2
btrfs / --subvol --name=@bazzite LABEL=$POOL_LABEL
EOF
cat /tmp/part.ks
%end

%post --interpreter=/bin/bash --erroronfail --log=/root/ks-post.log
set -euo pipefail

# The udev rule gets into Bazzite's initramfs via rpm-ostree initramfs-etc,
# which rebase.sh sets up once signed Bazzite is booted.
@DEGRADED_BOOT@

# /etc, not /usr/local: on ostree /usr/local points into /var, which is not
# populated yet at install time. /etc is carried across both rebases. The
# script deletes all of this once Bazzite (signed) is booted.
mkdir -p /etc/rebase-to-bazzite

cat > /etc/rebase-to-bazzite/rebase.sh <<'SCRIPT'
#!/bin/bash
# First-boot: Silverblue -> Bazzite (unverified) -> Bazzite (signed), then drops
# the rollback deployment and deletes itself and its unit.
# Bazzite's documented two-step rebase: the first image installs the signing
# policy needed to verify the second.
set -euo pipefail
IMAGE="@BAZZITE_IMAGE@"
DEGRADED_RULE=/etc/udev/rules.d/65-minipool-degraded.rules

booted_ref=$(rpm-ostree status --booted --json | python3 -c '
import json, sys
d = json.load(sys.stdin)["deployments"]
print(next(x for x in d if x.get("booted")).get("container-image-reference", ""))')
echo "booted image: $booted_ref"

case $booted_ref in
    "ostree-image-signed:docker://$IMAGE")
        # Bazzite's initramfs comes prebuilt in the image, so the degraded
        # boot entry's udev rule is added as an initramfs-etc overlay. It is
        # kept across updates. Needs its own deployment, so one more reboot.
        tracked=$(rpm-ostree status --booted --json | python3 -c '
import json, sys
d = json.load(sys.stdin)["deployments"]
print("\n".join(next(x for x in d if x.get("booted")).get("initramfs-etc", [])))')
        if ! grep -qxF "$DEGRADED_RULE" <<<"$tracked"; then
            echo "adding $DEGRADED_RULE to the initramfs"
            rpm-ostree initramfs-etc --track="$DEGRADED_RULE"
            shutdown -r +2 "Added the degraded-boot udev rule to the initramfs - rebooting in 2 minutes."
            exit 0
        fi
        # Leave what a fresh Bazzite install has: one deployment and none of
        # this. Each step is safe to repeat if a later one fails and the
        # service restarts.
        echo "Bazzite (signed) is booted - cleaning up."
        rpm-ostree cleanup --rollback
        # On a retry the unit file may already be gone, and disable would fail.
        systemctl disable rebase-to-bazzite.service || true
        rm -f /etc/systemd/system/rebase-to-bazzite.service \
              /etc/systemd/system/multi-user.target.wants/rebase-to-bazzite.service
        rm -rf /etc/rebase-to-bazzite
        systemctl daemon-reload
        echo "done - this unit and its script are removed."
        exit 0 ;;
    "ostree-unverified-registry:$IMAGE")
        target="ostree-image-signed:docker://$IMAGE" ;;
    *)
        target="ostree-unverified-registry:$IMAGE" ;;
esac

echo "rebasing to $target"
rpm-ostree rebase "$target"
shutdown -r +2 "Rebased to Bazzite ($target) - rebooting in 2 minutes."
SCRIPT
chmod 0755 /etc/rebase-to-bazzite/rebase.sh

cat > /etc/systemd/system/rebase-to-bazzite.service <<'UNIT'
[Unit]
Description=Rebase this Silverblue install to Bazzite
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/etc/rebase-to-bazzite/rebase.sh
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable rebase-to-bazzite.service
%end
