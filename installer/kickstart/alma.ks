# AlmaLinux "Server with GUI" onto drive 1, creating the shared btrfs raid1 pool.
#
# Partial kickstart: disk layout and package set are fixed here; language,
# keyboard, network/WiFi, hostname, timezone, root password and user account
# are deliberately left out so the graphical installer asks for them.
# Nothing is written to disk until you press "Begin Installation".
#
# Layout produced (sizes in MiB, S = equal raid member size computed in %pre):
#   drive 1: [ESP 600 /boot/efi] [ext4 2048 /boot] [btrfs S  ─┐
#   drive 2: [btrfs S ───────────────────────────────────────── ┘ raid1 "minipool"] [free ~2.6G for Bazzite]
#   subvolumes: @alma -> /   @alma_home -> /home
#
# @...@ placeholders are filled in by build-usb.sh from config.env.

graphical

%include /tmp/part.ks

%packages
@^graphical-server-environment
btrfs-progs
%end

%pre --interpreter=/bin/bash --log=/tmp/ks-pre.log
set -euo pipefail

ALMA_SERIAL="@ALMA_DISK_SERIAL@"
BAZZITE_SERIAL="@BAZZITE_DISK_SERIAL@"
POOL_LABEL="minipool"
ESP_MIB=600
BOOT_MIB=2048
SLACK_MIB=16

die() { echo "ERROR: $*" >&2; exit 1; }

# Whole internal disks: not removable, not on USB (excludes the installer stick).
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

if [[ -n $ALMA_SERIAL && -n $BAZZITE_SERIAL ]]; then
    D1=$(disk_by_serial "$ALMA_SERIAL")
    D2=$(disk_by_serial "$BAZZITE_SERIAL")
else
    D1=${DISKS[0]}
    D2=${DISKS[1]}
fi
[[ $D1 != "$D2" ]] || die "Alma and Bazzite resolved to the same disk ($D1)"

mib() { echo $(( $(blockdev --getsize64 "/dev/$1") / 1048576 )); }
S1=$(( $(mib "$D1") - ESP_MIB - BOOT_MIB - SLACK_MIB ))
S2=$(( $(mib "$D2") - ESP_MIB - BOOT_MIB - SLACK_MIB ))
S=$(( S1 < S2 ? S1 : S2 ))
[[ $S -gt 20480 ]] || die "disks too small (raid member would be ${S} MiB)"

echo "Alma disk: $D1   Bazzite disk: $D2   raid member size: ${S} MiB"

cat > /tmp/part.ks <<EOF
ignoredisk --only-use=$D1,$D2
zerombr
clearpart --all --initlabel --disklabel=gpt --drives=$D1,$D2
bootloader --boot-drive=$D1
part /boot/efi --fstype=efi  --size=$ESP_MIB  --ondisk=$D1
part /boot     --fstype=ext4 --size=$BOOT_MIB --ondisk=$D1
part btrfs.01 --size=$S --ondisk=$D1
part btrfs.02 --size=$S --ondisk=$D2
btrfs none --data=raid1 --metadata=raid1 --label=$POOL_LABEL btrfs.01 btrfs.02
btrfs /     --subvol --name=@alma      LABEL=$POOL_LABEL
btrfs /home --subvol --name=@alma_home LABEL=$POOL_LABEL
EOF
cat /tmp/part.ks
%end
