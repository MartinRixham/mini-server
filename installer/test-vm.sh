#!/usr/bin/env bash
# Rehearse the whole install in a UEFI QEMU VM with two blank NVMe disks.
#
#   ./test-vm.sh STICK            boot the installer stick (device or image file)
#   ./test-vm.sh --no-stick       boot the VM's own disks (e.g. to watch the Bazzite rebase)
#   ./test-vm.sh --reset          delete the VM disks and firmware vars, start over
#
# Build a test stick image without a real USB stick:
#   truncate -s 16G usb.img && LOOP=$(sudo losetup -fP --show usb.img)
#   ./build-usb.sh --device "$LOOP" --allow-loop && sudo losetup -d "$LOOP"
#   ./test-vm.sh usb.img
#
# Needs qemu-system-x86_64 and x86 OVMF firmware. On an x86 host with /dev/kvm
# this runs at normal speed; on anything else it falls back to emulation (TCG),
# which works but makes the installs take hours.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
VM="$HERE/.vm"
DISK_SIZE=80G

die() { echo "error: $*" >&2; exit 1; }

STICK="" NO_STICK=""
case ${1:-} in
    --reset)    rm -rf "$VM"; echo "VM reset"; exit 0 ;;
    --no-stick) NO_STICK=1 ;;
    ""|-h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          STICK=$1; [[ -r $STICK ]] || die "cannot read $STICK (for a device, run with sudo or add yourself to the disk group)" ;;
esac

command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"

CODE="" VARS_TEMPLATE=""
for pair in \
    /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
    /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
    /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
    /usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd; do
    if [[ -f ${pair%%:*} && -f ${pair##*:} ]]; then CODE=${pair%%:*}; VARS_TEMPLATE=${pair##*:}; break; fi
done
[[ -n $CODE ]] || die "x86_64 OVMF firmware not found (Fedora: edk2-ovmf, Debian: ovmf)"

mkdir -p "$VM"
[[ -f $VM/vars.fd ]] || cp "$VARS_TEMPLATE" "$VM/vars.fd"
for n in 1 2; do
    [[ -f $VM/disk$n.qcow2 ]] || qemu-img create -q -f qcow2 "$VM/disk$n.qcow2" "$DISK_SIZE"
done

if [[ $(uname -m) == x86_64 && -w /dev/kvm ]]; then
    ACCEL=(-accel kvm -cpu host)
else
    echo "warning: no KVM for x86_64 here - using slow emulation" >&2
    ACCEL=(-accel tcg,thread=multi -cpu max)
fi

STICK_ARGS=()
if [[ -z $NO_STICK ]]; then
    # snapshot=on: the VM never writes to the stick
    STICK_ARGS=(-drive "if=none,id=stick,format=raw,snapshot=on,file=$STICK"
                -device "usb-storage,bus=xhci.0,drive=stick,bootindex=0")
fi

exec qemu-system-x86_64 \
    -machine q35 "${ACCEL[@]}" -smp 4 -m 8G \
    -drive "if=pflash,format=raw,readonly=on,file=$CODE" \
    -drive "if=pflash,format=raw,file=$VM/vars.fd" \
    -drive "if=none,id=d1,format=qcow2,file=$VM/disk1.qcow2" -device nvme,serial=VMALMA0001,drive=d1 \
    -drive "if=none,id=d2,format=qcow2,file=$VM/disk2.qcow2" -device nvme,serial=VMBAZZ0002,drive=d2 \
    -device qemu-xhci,id=xhci -device usb-tablet,bus=xhci.0 \
    "${STICK_ARGS[@]}" \
    -nic user,model=virtio-net-pci \
    -device virtio-vga -display default
