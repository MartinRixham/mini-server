#!/usr/bin/env bash
# Install Bazzite onto drive 2 from a running AlmaLinux, with bootc.
#
#   sudo ./install-bazzite.sh [--image REF] [--user NAME | --no-user]
#                             [--root-ssh-keys FILE] [--yes]
#
# Adds Bazzite's ESP and /boot in the free space alma.ks left at the end of
# drive 2, creates the @bazzite subvolume in the minipool pool, and runs
# "bootc install to-filesystem" from the Bazzite image itself. Nothing that
# exists is reformatted. The image is pulled and verified against Bazzite's
# own signing policy, so the install tracks ostree-image-signed from the start.
#
# It also installs the degraded-boot entry and minipool-rebuild (degraded-boot.sh
# next to this script, or rendered in), copies Alma's NetworkManager
# connections, adds a firmware boot entry for drive 2 (after the existing
# ones), and sets up a one-shot first-boot unit that adds the minipool udev
# rule and unit to Bazzite's prebuilt initramfs and reboots once.
#
# The user who ran sudo (or --user NAME) is copied from Alma: same name, uid
# and password, in wheel, with a fresh home in Bazzite's /var/home.
# --root-ssh-keys is for the VM test.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
IMAGE=ghcr.io/ublue-os/bazzite:stable
SSH_KEYS="" YES="" USER_NAME=${SUDO_USER:-}
POOL_LABEL=minipool
ESP_MIB=600
BOOT_MIB=2048
ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
FRAGMENT=${DEGRADED_BOOT:-$HERE/kickstart/degraded-boot.sh}
[[ -f $FRAGMENT ]] || FRAGMENT=$HERE/degraded-boot.sh
T=/mnt/bazzite-install

die()  { echo "install-bazzite: $*" >&2; exit 1; }
step() { echo "==> $*"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        --image)         IMAGE=${2:?}; shift 2 ;;
        --root-ssh-keys) SSH_KEYS=$(realpath "${2:?}"); shift 2 ;;
        --user)          USER_NAME=${2:?}; shift 2 ;;
        --no-user)       USER_NAME=""; shift ;;
        --yes)           YES=1; shift ;;
        -h|--help)       sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               die "unknown option: $1" ;;
    esac
done

[[ $EUID == 0 ]] || die "run as root"
# shellcheck source=/dev/null
. /etc/os-release
[[ $ID == almalinux ]] || die "run this on the AlmaLinux install (this is $ID)"
[[ $(findmnt -no FSTYPE,FSROOT /) == "btrfs /@alma" ]] || die "/ is not @alma on btrfs"
[[ -f $FRAGMENT ]] || die "degraded-boot.sh not found (set DEGRADED_BOOT=)"
[[ -z $SSH_KEYS || -s $SSH_KEYS ]] || die "$SSH_KEYS is empty"
USER_UID="" USER_HASH="" USER_GECOS=""
if [[ -n $USER_NAME ]]; then
    IFS=: read -r _ _ USER_UID _ USER_GECOS _ < <(getent passwd "$USER_NAME") \
        || die "no user '$USER_NAME' on Alma (use --user NAME or --no-user)"
    (( USER_UID >= 1000 )) || die "'$USER_NAME' is a system account (uid $USER_UID)"
    USER_HASH=$(getent shadow "$USER_NAME" | cut -d: -f2)
fi

# --- which disk ------------------------------------------------------------------
# Drive 1 holds Alma's /boot/efi; drive 2 is the disk with the other pool member.
D1=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /boot/efi)")
mapfile -t MEMBERS < <(btrfs filesystem show / | awk '$1 == "devid" {print $NF}')
[[ ${#MEMBERS[@]} == 2 ]] || die "pool has ${#MEMBERS[@]} members, expected 2 (degraded? run minipool-rebuild first)"
D2="" M2=""
for m in "${MEMBERS[@]}"; do
    d=/dev/$(lsblk -no PKNAME "$m")
    [[ $d == "$D1" ]] || { D2=$d M2=$m; }
done
[[ -n $D2 ]] || die "could not find drive 2 (both pool members are on $D1?)"
[[ $(cat "/sys/class/block/${M2##*/}/partition") == 1 ]] \
    || die "$M2 is not partition 1 of $D2 - not the layout alma.ks makes"
if lsblk -nro PARTTYPE "$D2" | grep -qi "$ESP_GUID"; then
    die "$D2 already has an EFI partition - Bazzite looks installed already"
fi
[[ $(findmnt -no LABEL /) == "$POOL_LABEL" ]] || die "/ is not on the $POOL_LABEL pool"
POOL_UUID=$(findmnt -no UUID /)
mkdir -p "$T"
mountpoint -q "$T" && die "$T is in use"
mount -o subvol=/ "UUID=$POOL_UUID" "$T"
if [[ -e $T/@bazzite ]]; then umount "$T"; die "subvolume @bazzite already exists"; fi
umount "$T"

free_mib=$(( $(sfdisk --list-free --bytes "$D2" | awk '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ {s=$4} END {print s+0}') / 1048576 ))
(( free_mib >= ESP_MIB + BOOT_MIB )) || die "only ${free_mib} MiB free at the end of $D2"

echo "Drive 1 (AlmaLinux): $D1 $(lsblk -dno MODEL,SERIAL "$D1")"
echo "Drive 2 (Bazzite):   $D2 $(lsblk -dno MODEL,SERIAL "$D2"), ${free_mib} MiB free"
echo "Image: $IMAGE"
echo "User:  ${USER_NAME:-none (root only)}"
echo "This adds an ESP and /boot on $D2 and a @bazzite subvolume. Nothing existing is erased."
if [[ -z $YES ]]; then
    read -rp "Type yes to continue: " a
    [[ $a == yes ]] || die "cancelled"
fi

# --- partitions and subvolume -----------------------------------------------------
part_of() { echo "$1$([[ $1 =~ [0-9]$ ]] && echo p)$2"; }
step "adding the ESP and /boot to $D2"
printf 'size=%sMiB, type=uefi\nsize=%sMiB, type=linux\n' "$ESP_MIB" "$BOOT_MIB" \
    | sfdisk --append --no-reread "$D2"
partx -u "$D2" || true
udevadm settle
ESP=$(part_of "$D2" 2) BOOT=$(part_of "$D2" 3)
[[ -b $ESP && -b $BOOT ]] || die "$ESP or $BOOT did not appear"
mkfs.vfat -F 32 -n BAZZITE-ESP "$ESP" >/dev/null
mkfs.ext4 -q -F -L bazzite-boot "$BOOT"
udevadm settle
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")

cleanup() { umount -R "$T" 2>/dev/null || true; }
trap cleanup EXIT
mount -o subvol=/ "UUID=$POOL_UUID" "$T"
btrfs subvolume create "$T/@bazzite"
umount "$T"
mount -o subvol=@bazzite "UUID=$POOL_UUID" "$T"
mkdir -p "$T/boot"
mount "$BOOT" "$T/boot"
mkdir -p "$T/boot/efi"
mount "$ESP" "$T/boot/efi"

# --- bootc --------------------------------------------------------------------------
command -v podman >/dev/null || { step "installing podman"; dnf -y -q install podman; }
step "pulling $IMAGE"
podman pull "$IMAGE"

keys_mount=() keys_arg=()
if [[ -n $SSH_KEYS ]]; then
    keys_mount=(-v "$SSH_KEYS:/run/root-keys:ro,z")
    keys_arg=(--root-ssh-authorized-keys /run/root-keys)
fi
in_image() {  # command... : run in the Bazzite image, with the target at /target
    podman run --rm --privileged --pid=host \
        --security-opt label=type:unconfined_t \
        -v /dev:/dev -v /var/lib/containers:/var/lib/containers \
        -v "$T:/target" \
        "${keys_mount[@]}" \
        "$IMAGE" "$@"
}
ORDER=$(efibootmgr | sed -n 's/^BootOrder: //p')

step "bootc install to-filesystem"
# --skip-finalize: finalizing freezes the filesystem, and this one is Alma's
# root too.
# --bootloader none: bootc hands bootupd the disk of the root filesystem, and
# with a pool spanning both drives that is drive 1, so bootupd would install
# onto Alma's ESP. bootupd runs below, pointed at drive 2.
in_image bootc install to-filesystem \
        --target-imgref "$IMAGE" --enforce-container-sigpolicy \
        --root-mount-spec "UUID=$POOL_UUID" \
        --boot-mount-spec "UUID=$BOOT_UUID" \
        --karg "rootflags=subvol=@bazzite" \
        --skip-finalize --bootloader none \
        "${keys_arg[@]}" \
        /target

step "installing the bootloader on $D2 (bootupd)"
in_image bootupctl backend install --write-uuid --update-firmware --auto \
    --with-static-configs --device "$D2" /target
[[ -d $T/boot/efi/EFI/fedora ]] || die "bootupd did not install to Bazzite's ESP ($ESP)"
[[ ! -e /boot/efi/EFI/fedora ]] || die "Bazzite's bootloader ended up on Alma's ESP (/boot/efi/EFI/fedora)"

# bootupd can't always reach the firmware variables from the container (in CI
# it added nothing). Then add the entry here, from Alma, pointing at drive 2's ESP.
ESP_PARTUUID=$(blkid -s PARTUUID -o value "$ESP")
if ! efibootmgr -v | grep -qi "$ESP_PARTUUID"; then
    case $(uname -m) in x86_64) shim=shimx64.efi ;; aarch64) shim=shimaa64.efi ;; *) die "unsupported arch $(uname -m)" ;; esac
    [[ -f $T/boot/efi/EFI/fedora/$shim ]] || die "no $shim in Bazzite's ESP ($ESP)"
    step "adding a firmware boot entry for Bazzite (\\EFI\\fedora\\$shim on $ESP)"
    efibootmgr -q -c -d "$D2" -p 2 -L Bazzite -l "\\EFI\\fedora\\$shim"
fi
efibootmgr -v | grep -qi "$ESP_PARTUUID" || die "no firmware boot entry for Bazzite's ESP ($ESP)"

# bootupd and efibootmgr -c put the new entry first. Keep Alma the default: the
# old order, then whatever is new.
if [[ -n $ORDER ]]; then
    now=$(efibootmgr | sed -n 's/^BootOrder: //p')
    added=$(tr ',' '\n' <<<"$now" | grep -vxF -f <(tr ',' '\n' <<<"$ORDER") | paste -sd, || true)
    efibootmgr -q -o "$ORDER${added:+,$added}"
    step "firmware boot order: $ORDER${added:+,$added} (Bazzite: ${added:-none added})"
fi

# --- into the new deployment's /etc ---------------------------------------------
mapfile -t DEPLOYS < <(compgen -G "$T/ostree/deploy/*/deploy/*.0" || true)
[[ ${#DEPLOYS[@]} == 1 ]] || die "expected one deployment, found ${#DEPLOYS[@]}"
DEP=${DEPLOYS[0]}
step "configuring $DEP"

# The deployment's /var is empty until boot mounts the stateroot's over it.
VAR=$(dirname "$(dirname "$DEP")")/var
# Everything changed after this is relabelled below; what bootc wrote is not.
STAMP=$(mktemp)
mkdir -p "$DEP/proc" "$VAR/home"
mount -t proc proc "$DEP/proc"
mount --bind "$VAR" "$DEP/var"
chroot "$DEP" /bin/bash -s < "$FRAGMENT"

if [[ -n $USER_NAME ]]; then
    step "adding user $USER_NAME (uid $USER_UID, wheel, password from Alma)"
    chroot "$DEP" useradd -m -u "$USER_UID" -G wheel -c "$USER_GECOS" -p "$USER_HASH" "$USER_NAME"
fi

if compgen -G "/etc/NetworkManager/system-connections/*" >/dev/null; then
    cp -a /etc/NetworkManager/system-connections/. "$DEP/etc/NetworkManager/system-connections/"
fi
[[ -n $SSH_KEYS ]] && chroot "$DEP" systemctl enable sshd.service

# The degraded udev rule and minipool-ready.service must be in the initramfs,
# which Bazzite's image ships prebuilt: add them as an initramfs-etc overlay on
# first boot (needs a running rpm-ostree), reboot once, then remove this unit.
mkdir -p "$DEP/etc/minipool"
cat > "$DEP/etc/minipool/initramfs-firstboot" <<'SCRIPT'
#!/bin/bash
set -euo pipefail
RULE=/etc/udev/rules.d/65-minipool-degraded.rules
UNIT=/etc/systemd/system/minipool-ready.service
tracked=$(rpm-ostree status --booted --json | python3 -c '
import json, sys
d = json.load(sys.stdin)["deployments"]
print("\n".join(next(x for x in d if x.get("booted")).get("initramfs-etc", [])))')
if grep -qxF "$RULE" <<<"$tracked" && grep -qxF "$UNIT" <<<"$tracked"; then
    echo "minipool rule and unit are in the initramfs - removing this unit"
    rpm-ostree cleanup --rollback
    systemctl disable minipool-initramfs-firstboot.service || true
    rm -f /etc/systemd/system/minipool-initramfs-firstboot.service /etc/minipool/initramfs-firstboot
    systemctl daemon-reload
    exit 0
fi
rpm-ostree initramfs-etc --track="$RULE" --track="$UNIT"
shutdown -r +1 "Added the minipool udev rule to the initramfs - rebooting."
SCRIPT
chmod 0755 "$DEP/etc/minipool/initramfs-firstboot"
cat > "$DEP/etc/systemd/system/minipool-initramfs-firstboot.service" <<'UNIT'
[Unit]
Description=Add the minipool udev rule and unit to Bazzite's initramfs
After=tuned.service bazzite-hardware-setup.service

[Service]
Type=oneshot
ExecStart=/etc/minipool/initramfs-firstboot
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
UNIT
chroot "$DEP" systemctl enable minipool-initramfs-firstboot.service
umount "$DEP/proc"

# Label what was written here, and only that. Bazzite's own setfiles and
# policy: Alma's setfiles can't read Bazzite's newer file_contexts. Relabelling
# all of /etc fails: some of the types Bazzite's policy gives files bootc wrote
# (/etc/kmscon, /etc/openvpn) are unknown to Alma's running kernel, which
# refuses to set them ("Invalid argument"). Ours all use common types.
step "relabelling the files written here"
in_dep="/target${DEP#"$T"}"
mapfile -t RELABEL < <(cd "$DEP" && find etc -cnewer "$STAMP" ! -type d -printf '/%p\n')
RELABEL=("${RELABEL[@]/#/$in_dep}" "$in_dep/etc/minipool" "$in_dep/var/home")
rm -f "$STAMP"
# shellcheck disable=SC2016  # expands in the container
in_image sh -c 'set -e; d=$1; shift; p=$(ls "$d"/etc/selinux/targeted/policy/policy.* | sort -V | tail -1)
    setfiles -v -c "$p" -r "$d" "$d/etc/selinux/targeted/contexts/files/file_contexts" "$@"' _ "$in_dep" "${RELABEL[@]}"
umount "$DEP/var"

cleanup
trap - EXIT
step "pulling the image out of Alma's container storage"
podman rmi "$IMAGE" >/dev/null || true
step "done. Boot drive 2 (Bazzite) from the firmware boot menu. Its first boot reboots once by itself."
