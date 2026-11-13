#!/usr/bin/env bash
# Unattended end-to-end install in a UEFI QEMU/KVM VM with two NVMe disks:
# AlmaLinux, then Silverblue, then the first-boot rebase to Bazzite. Each
# installed system is booted and checked over SSH.
#
#   tests/vm-install.sh [--work DIR] STEP...
#
# Steps, in order (or "all"):
#   prepare             fetch + verify ISOs, render CI kickstarts, create blank disks
#   install-alma        boot the Alma ISO with alma.ks, wait for it to power off
#   check-alma          boot drive 1 (Alma), check layout; after Bazzite, also
#                       checks Alma still boots and sees @bazzite
#   install-silverblue  boot the Fedora ISO with silverblue.ks
#   check-bazzite       boot drive 2, check layout, wait for the rebase to finish
#                       (signed Bazzite image booted), check again
#
# Differences from a real install (only for unattended running):
# - the ISOs' kernels are booted directly with inst.ks=, not through Ventoy
# - the kickstarts get a CI add-on: text-only install, language, keyboard,
#   timezone, a throwaway root password, an SSH key for root, poweroff at the
#   end; alma.ks also gets explicit AlmaLinux mirrorlists
# - disk serials are pinned (VMALMA0001/VMBAZZ0002) so the checks know which
#   QEMU disk is which
#
# State lives in DIR (default .vm-ci/); logs and failure screenshots in DIR/logs.
# Needs: qemu-system-x86_64, qemu-img, x86_64 OVMF, xorriso, ssh, jq, and KVM
# (VM_ACCEL=tcg forces emulation; expect many hours).
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK="$HERE/.vm-ci"
INSTALL_TIMEOUT=${INSTALL_TIMEOUT:-150m}
REBASE_TIMEOUT_MIN=${REBASE_TIMEOUT_MIN:-150}
SSH_PORT=${SSH_PORT:-2222}
ALMA_SERIAL=VMALMA0001
BAZZITE_SERIAL=VMBAZZ0002

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ ${1:-} == --work ]] && { WORK=$(realpath -m "${2:?}"); shift 2; }
[[ $# -gt 0 ]] || { sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
LOGS="$WORK/logs"
mkdir -p "$LOGS"

# --- QEMU --------------------------------------------------------------------
find_ovmf() {
    local pair
    for pair in \
        /usr/share/OVMF/OVMF_CODE_4M.fd:/usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/edk2/ovmf/OVMF_CODE.fd:/usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd:/usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/qemu/edk2-x86_64-code.fd:/usr/share/qemu/edk2-i386-vars.fd; do
        if [[ -f ${pair%%:*} && -f ${pair##*:} ]]; then echo "$pair"; return; fi
    done
    die "x86_64 OVMF firmware not found (Debian/Ubuntu: ovmf, Fedora: edk2-ovmf)"
}

accel() {
    if [[ ${VM_ACCEL:-} != tcg && $(uname -m) == x86_64 && -w /dev/kvm ]]; then
        echo "-accel kvm -cpu host"
    else
        echo "warning: no KVM - using slow emulation" >&2
        echo "-accel tcg,thread=multi -cpu max"
    fi
}

# Common VM: two NVMe disks; $1 = serial of the disk to boot first (or "").
qemu_args() {
    local boot=$1 code
    code=$(find_ovmf); code=${code%%:*}
    # shellcheck disable=SC2207  # word splitting of accel() is intended
    QEMU=(qemu-system-x86_64 -machine q35 $(accel) -smp 4 -m 6G
          -drive "if=pflash,format=raw,readonly=on,file=$code"
          -drive "if=pflash,format=raw,file=$WORK/vars.fd")
    local n serial bootindex
    for n in 1 2; do
        serial=$ALMA_SERIAL; [[ $n == 2 ]] && serial=$BAZZITE_SERIAL
        bootindex=""; [[ $serial == "$boot" ]] && bootindex=,bootindex=1
        QEMU+=(-drive "if=none,id=d$n,format=qcow2,file=$WORK/disk$n.qcow2"
               -device "nvme,serial=$serial,drive=d$n$bootindex")
    done
    QEMU+=(-device virtio-vga -display none
           -monitor "unix:$WORK/monitor.sock,server,nowait")
}

monitor() {  # command...
    python3 - "$WORK/monitor.sock" "$*" <<'EOF'
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.connect(sys.argv[1])
s.sendall(sys.argv[2].encode() + b"\n")
time.sleep(2)
s.close()
EOF
}

screenshot() {  # name
    [[ -S $WORK/monitor.sock ]] || return 0
    if monitor "screendump $LOGS/$1.png -f png" 2>/dev/null; then info "screenshot: $LOGS/$1.png"; fi
}

vm_running() { [[ -f $WORK/qemu.pid ]] && kill -0 "$(cat "$WORK/qemu.pid")" 2>/dev/null; }

# --- SSH ---------------------------------------------------------------------
vm_ssh() {
    ssh -i "$WORK/id_ed25519" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        root@127.0.0.1 "$@"
}

wait_ssh() {  # minutes
    local deadline=$((SECONDS + $1 * 60))
    until vm_ssh true 2>/dev/null; do
        vm_running || die "VM exited before SSH came up (see $LOGS)"
        [[ $SECONDS -lt $deadline ]] || { screenshot ssh-timeout; die "no SSH after $1 minutes"; }
        sleep 10
    done
}

# --- steps -------------------------------------------------------------------
step_prepare() {
    # shellcheck source=config.env
    source "$HERE/config.env"
    { cat "$HERE/config.env"
      echo "ALMA_DISK_SERIAL=$ALMA_SERIAL"
      echo "BAZZITE_DISK_SERIAL=$BAZZITE_SERIAL"; } > "$WORK/config.env"
    CONFIG="$WORK/config.env" "$HERE/build-usb.sh" --fetch-only
    rm -rf "$WORK/render"
    CONFIG="$WORK/config.env" "$HERE/build-usb.sh" --render-only "$WORK/render"

    [[ -f $WORK/id_ed25519 ]] || ssh-keygen -q -t ed25519 -N "" -C vm-install -f "$WORK/id_ed25519"
    local pubkey password
    pubkey=$(cat "$WORK/id_ed25519.pub")
    password=$(head -c 18 /dev/urandom | base64)

    local name iso
    for name in alma silverblue; do
        if [[ $name == alma ]]; then
            iso=$(find "$HERE/.cache" -maxdepth 1 -name "AlmaLinux-$ALMA_MAJOR.*-x86_64-boot.iso" | sort -V | tail -1)
        else
            iso=$(find "$HERE/.cache" -maxdepth 1 -name "Fedora-Everything-netinst-x86_64-$FEDORA_VERSION-*.iso" | sort -V | tail -1)
        fi
        [[ -n $iso ]] || die "no $name ISO in .cache"
        echo "$iso" > "$WORK/$name.iso-path"

        { sed 's/^graphical$/cmdline/' "$WORK/render/ventoy/$name.ks"
          cat <<EOF

# ---- CI add-on (tests/vm-install.sh): answers what the GUI would ask ----
lang en_US.UTF-8
keyboard us
timezone UTC --utc
network --bootproto=dhcp --device=link --activate
rootpw --plaintext $password
sshkey --username=root "$pubkey"
services --enabled=sshd
firstboot --disable
poweroff
EOF
          if [[ $name == alma ]]; then cat <<EOF
url --mirrorlist=https://mirrors.almalinux.org/mirrorlist/$ALMA_MAJOR/baseos
repo --name=ci-appstream --mirrorlist=https://mirrors.almalinux.org/mirrorlist/$ALMA_MAJOR/appstream
EOF
          fi
        } > "$WORK/$name.ks"
        grep -q '^cmdline$' "$WORK/$name.ks" || die "$name.ks: no 'graphical' line to switch to cmdline"

        xorriso -as mkisofs -quiet -V CIKS -o "$WORK/$name-ks.iso" -graft-points "ks.cfg=$WORK/$name.ks"
        xorriso -osirrox on -indev "$iso" \
            -extract /images/pxeboot/vmlinuz "$WORK/$name.vmlinuz" \
            -extract /images/pxeboot/initrd.img "$WORK/$name.initrd" 2>/dev/null
        [[ -s $WORK/$name.vmlinuz && -s $WORK/$name.initrd ]] || die "could not extract the kernel from $iso"
        blkid -p -o value -s LABEL "$iso" > "$WORK/$name.label"
        [[ -s $WORK/$name.label ]] || die "could not read the volume label of $iso"
        info "$name: $(basename "$iso") (label $(cat "$WORK/$name.label"))"
    done

    local pair; pair=$(find_ovmf)
    rm -f "$WORK"/disk?.qcow2 "$WORK/vars.fd" "$WORK"/*.done
    cp "${pair##*:}" "$WORK/vars.fd"
    qemu-img create -q -f qcow2 "$WORK/disk1.qcow2" 80G
    qemu-img create -q -f qcow2 "$WORK/disk2.qcow2" 80G
    info "prepared $WORK"
}

install() {  # alma|silverblue
    local name=$1 label
    label=$(sed 's/ /\\x20/g' "$WORK/$name.label")
    qemu_args ""
    # shellcheck disable=SC2054  # commas are inside QEMU option values
    QEMU+=(-drive "if=none,id=iso,media=cdrom,readonly=on,file=$(cat "$WORK/$name.iso-path")"
           -device ide-cd,bus=ide.0,drive=iso
           -drive "if=none,id=ks,media=cdrom,readonly=on,file=$WORK/$name-ks.iso"
           -device ide-cd,bus=ide.1,drive=ks
           -kernel "$WORK/$name.vmlinuz" -initrd "$WORK/$name.initrd"
           -append "inst.stage2=hd:LABEL=$label inst.ks=hd:LABEL=CIKS:/ks.cfg inst.cmdline console=tty0 console=ttyS0,115200"
           -nic user,model=virtio-net-pci
           -serial stdio -no-reboot)
    info "installing $name (timeout $INSTALL_TIMEOUT; serial log $LOGS/install-$name.log)"
    local rc=0
    timeout "$INSTALL_TIMEOUT" "${QEMU[@]}" < /dev/null 2>&1 | tee "$LOGS/install-$name.log" || rc=$?
    if [[ $rc -ne 0 ]]; then
        [[ $rc -eq 124 ]] && echo "install did not finish within $INSTALL_TIMEOUT" >&2
        die "$name install failed (exit $rc)"
    fi
    # Anaconda powers off after a successful install. A failed one either waits
    # (caught by the timeout) or reboots (-no-reboot exits; the boot check fails).
    touch "$WORK/$name.done"
    info "$name installed"
}

boot() {  # serial-of-disk-to-boot log-name
    vm_running && die "a VM is already running (pid $(cat "$WORK/qemu.pid"))"
    qemu_args "$1"
    QEMU+=(-nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
           -serial "file:$LOGS/$2.serial.log"
           -daemonize -pidfile "$WORK/qemu.pid")
    info "booting $2"
    "${QEMU[@]}"
    trap 'rc=$?; [[ $rc -eq 0 ]] || screenshot "'"$2"'-failed"; stop' EXIT
    wait_ssh 15
}

stop() {
    vm_running || return 0
    vm_ssh systemctl poweroff 2>/dev/null || true
    local deadline=$((SECONDS + 120))
    while vm_running && [[ $SECONDS -lt $deadline ]]; do sleep 2; done
    vm_running && { monitor quit 2>/dev/null || true; sleep 2; }
    vm_running && kill "$(cat "$WORK/qemu.pid")"
    rm -f "$WORK/qemu.pid"
}

# Runs inside the guest. MODE (alma|bazzite) and the expectations are prepended.
GUEST_CHECKS=$(cat <<'EOF'
set -euo pipefail
ESP=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
FAILED=0
ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; FAILED=1; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

disk_of() { lsblk -dno NAME,SERIAL | awk -v s="$1" '$2 == s {print $1}'; }
A=$(disk_of "$ALMA_SERIAL") B=$(disk_of "$BAZZITE_SERIAL")
[[ -n $A && -n $B ]] || { echo "  FAIL: disks not found by serial"; lsblk; exit 1; }
esps()   { lsblk -nro PARTTYPE "/dev/$1" | grep -ci "$ESP" || true; }
disk_holding() { lsblk -no PKNAME "$(findmnt -no SOURCE "$1")"; }
fsroot() { findmnt -no FSROOT "$1"; }

. /etc/os-release
echo "  booted: $PRETTY_NAME, kernel $(uname -r)"
check "drive 1 ($A) has one ESP" test "$(esps "$A")" = 1
check "drive 2 ($B) has $BAZZITE_ESPS ESP(s)" test "$(esps "$B")" = "$BAZZITE_ESPS"

if [[ $MODE == alma ]]; then
    check "running AlmaLinux"       test "$ID" = almalinux
    check "/ is btrfs subvol @alma" test "$(findmnt -no FSTYPE /):$(fsroot /)" = btrfs:/@alma
    check "/home is subvol @alma_home" test "$(fsroot /home)" = /@alma_home
    check "/boot on drive 1"        test "$(disk_holding /boot)" = "$A"
    check "/boot/efi on drive 1"    test "$(disk_holding /boot/efi)" = "$A"
    POOL=/
else
    check "/sysroot is btrfs subvol @bazzite" test "$(findmnt -no FSTYPE /sysroot):$(fsroot /sysroot)" = btrfs:/@bazzite
    check "/boot on drive 2"        test "$(disk_holding /boot)" = "$B"
    check "rebase service installed" test -x /etc/rebase-to-bazzite/rebase.sh
    POOL=/sysroot
fi

show=$(btrfs filesystem show "$POOL")
check "pool is labelled minipool" grep -q "Label: 'minipool'" <<<"$show"
check "pool has 2 devices"        grep -q "Total devices 2" <<<"$show"
for dev in $(awk '$1 == "devid" {print $NF}' <<<"$show"); do
    echo "  pool member: $dev on $(lsblk -no PKNAME "$dev")"
done
members=$(awk '$1 == "devid" {print $NF}' <<<"$show" | xargs -n1 lsblk -no PKNAME | sort | tr '\n' ' ')
check "one pool member per drive" test "$members" = "$(printf '%s\n' "$A" "$B" | sort | tr '\n' ' ')"
df=$(btrfs filesystem df "$POOL")
check "data is RAID1"     grep -q '^Data, RAID1:' <<<"$df"
check "metadata is RAID1" grep -q '^Metadata, RAID1:' <<<"$df"
check "system is RAID1"   grep -q '^System, RAID1:' <<<"$df"
subvols=$(btrfs subvolume list "$POOL" | awk '{print $NF}')
for sv in @alma @alma_home $EXPECT_BAZZITE_SUBVOL; do
    check "subvolume $sv exists" grep -qx "$sv" <<<"$subvols"
done
exit $FAILED
EOF
)

guest_check() {  # alma|bazzite
    local bazzite_installed=0
    [[ -f $WORK/silverblue.done ]] && bazzite_installed=1
    info "checks ($1)"
    { echo "MODE=$1 ALMA_SERIAL=$ALMA_SERIAL BAZZITE_SERIAL=$BAZZITE_SERIAL"
      echo "BAZZITE_ESPS=$bazzite_installed"
      echo "EXPECT_BAZZITE_SUBVOL=$([[ $bazzite_installed == 1 ]] && echo @bazzite)"
      echo "$GUEST_CHECKS"; } | vm_ssh bash -s
}

booted_image() {
    vm_ssh rpm-ostree status --booted --json 2>/dev/null \
        | jq -r '.deployments[] | select(.booted) | .["container-image-reference"] // ""'
}

step_check_alma() {
    [[ -f $WORK/alma.done ]] || die "run install-alma first"
    local name=boot-alma
    [[ -f $WORK/silverblue.done ]] && name="boot-alma-after-bazzite"
    boot "$ALMA_SERIAL" "$name"
    guest_check alma
    stop
}

step_check_bazzite() {
    [[ -f $WORK/silverblue.done ]] || die "run install-silverblue first"
    # shellcheck source=/dev/null
    source "$WORK/config.env"
    boot "$BAZZITE_SERIAL" boot-bazzite
    guest_check bazzite
    vm_ssh systemctl is-enabled rebase-to-bazzite.service >/dev/null \
        || [[ -n $(vm_ssh 'ls /var/lib/rebase-to-bazzite/done 2>/dev/null') ]] \
        || die "rebase-to-bazzite.service is not enabled"

    local want="ostree-image-signed:docker://$BAZZITE_IMAGE" last="" ref
    local deadline=$((SECONDS + REBASE_TIMEOUT_MIN * 60))
    info "waiting for the rebase to $want (timeout ${REBASE_TIMEOUT_MIN} min)"
    while :; do
        ref=$(booted_image || true)
        if [[ -n $ref && $ref != "$last" ]]; then info "booted image: $ref"; last=$ref; fi
        if [[ $ref == "$want" ]] && vm_ssh test -e /var/lib/rebase-to-bazzite/done 2>/dev/null; then
            break
        fi
        if [[ $SECONDS -ge $deadline ]]; then
            vm_ssh journalctl -b -u rebase-to-bazzite --no-pager -n 50 || true
            screenshot rebase-timeout
            die "rebase did not finish within $REBASE_TIMEOUT_MIN minutes"
        fi
        vm_running || die "VM exited during the rebase"
        sleep 30
    done
    vm_ssh journalctl -u rebase-to-bazzite --no-pager > "$LOGS/rebase-to-bazzite.log" 2>&1 || true
    vm_ssh rpm-ostree status
    guest_check bazzite
    local state
    state=$(vm_ssh systemctl is-enabled rebase-to-bazzite.service 2>/dev/null || true)
    [[ $state == disabled ]] || die "rebase-to-bazzite.service is still '$state' after finishing"
    info "rebase done; service disabled itself"
    stop
}

steps=("$@")
[[ ${steps[*]} == all ]] && steps=(prepare install-alma check-alma install-silverblue check-bazzite check-alma)
for s in "${steps[@]}"; do
    case $s in
        prepare)            step_prepare ;;
        install-alma)       install alma ;;
        install-silverblue) [[ -f $WORK/alma.done ]] || die "run install-alma first"; install silverblue ;;
        check-alma)         (step_check_alma) ;;
        check-bazzite)      (step_check_bazzite) ;;
        *) die "unknown step: $s" ;;
    esac
done
