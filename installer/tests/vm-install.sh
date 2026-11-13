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
#                       (signed Bazzite booted, rebase service gone), check again,
#                       then check it matches a fresh Bazzite install: no failed
#                       units, no leftovers, one clean deployment, Bazzite's
#                       image info, no Silverblue /etc kept by the merge
#   degraded-alma       drive 2 dies: on throwaway overlays of the disks, pick
#                       Alma's degraded entry, swap drive 2 for a blank disk,
#                       boot with one SSD missing, rebuild the pool onto the
#                       blank disk as README.md says, boot normally, check raid1
#   degraded-bazzite    the same with drive 1 dying and Bazzite surviving
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
[[ $# -gt 0 ]] || { sed -n '2,/^[^#]/s/^# \{0,1\}//p' "$0"; exit 1; }
LOGS="$WORK/logs"
mkdir -p "$LOGS"
# The VM's disks as file:serial, and its firmware variables. The degraded
# steps swap in overlays and a blank disk.
DISKS=("$WORK/disk1.qcow2:$ALMA_SERIAL" "$WORK/disk2.qcow2:$BAZZITE_SERIAL")
VARS=$WORK/vars.fd

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

# Common VM: the NVMe disks in DISKS; $1 = serial of the disk to boot first (or "").
qemu_args() {
    local boot=$1 code
    code=$(find_ovmf); code=${code%%:*}
    # shellcheck disable=SC2207  # word splitting of accel() is intended
    QEMU=(qemu-system-x86_64 -machine q35 $(accel) -smp 4 -m 6G
          -drive "if=pflash,format=raw,readonly=on,file=$code"
          -drive "if=pflash,format=raw,file=$VARS")
    local n=0 d serial bootindex
    for d in "${DISKS[@]}"; do
        n=$((n + 1)) serial=${d##*:}
        bootindex=""; [[ $serial == "$boot" ]] && bootindex=,bootindex=1
        QEMU+=(-drive "if=none,id=d$n,format=qcow2,file=${d%:*}"
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
    POOL=/sysroot
fi

# The "one SSD missing (degraded)" boot entry and what it needs.
cfg=/boot/grub2/custom.cfg
check "booted normally, not degraded" bash -c '! grep -Eq "rootflags=[^ ]*degraded" /proc/cmdline'
check "degraded udev rule installed" test -s /etc/udev/rules.d/65-minipool-degraded.rules
check "minipool-degraded-boot.service is active" systemctl is-active minipool-degraded-boot.service
check "custom.cfg has the degraded entry" grep -q -- "--id minipool-degraded" "$cfg"
check "degraded entry adds degraded to rootflags" grep -Eq "^  linux .* rootflags=([^ ]*,)?degraded( |$)" "$cfg"
kernel=$(awk '$1 == "linux" {print $2; exit}' "$cfg" 2>/dev/null || true)
check "degraded entry's kernel exists (/boot$kernel)" test -f "/boot$kernel"
if [[ $MODE == alma ]]; then
    check "initramfs has the degraded udev rule" \
        bash -c "lsinitrd /boot/initramfs-\$(uname -r).img | grep -q 65-minipool-degraded.rules"
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

# --- "same as a fresh Bazzite install" checks (host side) ---------------------
CHECK_FAILED=0
ok()  { echo "  ok: $*"; }
bad() { echo "  FAIL: $*"; CHECK_FAILED=1; }
indent() { local l; while IFS= read -r l; do echo "        $l"; done; }

# Fingerprint of each file under the booted image's default /etc (/usr/etc):
# "<sha256 or link:target>  <path relative to /etc>".
# shellcheck disable=SC2016  # expands in the guest
USR_ETC_SUMS='cd /usr/etc && { find . -type f -exec sha256sum {} + && find . -type l -printf "link:%l  %p\n"; } | sed "s|  \./|  |"'

# /etc files any install rewrites after an update (systemd-sysusers, ldconfig),
# or rebuilds from /usr at boot (systemd-hwdb-update, bootc-update-ca-trust),
# or ostree recompiles on every new deployment (semodule -N --refresh, the
# compiled SELinux policy), so they differ from the image default on a fresh
# install too. check_selinux_modules checks the loaded policy itself.
ETC_MERGE_ALLOW='^(passwd|group|shadow|gshadow|subuid|subgid)-?$|^ld\.so\.cache$|^udev/hwdb\.bin$|^pki/ca-trust/extracted/|^selinux/[^/]+/(active/commit_num|active/policy\.kern|policy/policy\.[0-9]+)$'

check_settled() {
    local state failed
    state=$(vm_ssh 'timeout 600 systemctl is-system-running --wait' 2>/dev/null || true)
    failed=$(vm_ssh systemctl --failed --plain --no-legend 2>/dev/null || true)
    if [[ $state == running ]]; then ok "system is running, no failed units"
    else bad "system state '${state:-unknown}'; failed units:"; indent <<<"$failed"; fi
}

check_no_leftovers() {
    local p
    for p in /etc/rebase-to-bazzite /etc/systemd/system/rebase-to-bazzite.service \
             /etc/systemd/system/multi-user.target.wants/rebase-to-bazzite.service \
             /var/lib/rebase-to-bazzite; do
        if vm_ssh test ! -e "$p"; then ok "$p removed"; else bad "$p still exists"; fi
    done
    local load; load=$(vm_ssh systemctl show -P LoadState rebase-to-bazzite.service || true)
    if [[ $load == not-found ]]; then ok "rebase-to-bazzite.service unknown to systemd"
    else bad "rebase-to-bazzite.service LoadState is '$load'"; fi
}

DEGRADED_RULE=/etc/udev/rules.d/65-minipool-degraded.rules

check_deployments() {  # wanted-image-ref
    local status others local_state
    status=$(vm_ssh rpm-ostree status --json)
    # A staged automatic update of the same image is fine; anything else is not.
    others=$(jq -r --arg w "$1" '.deployments[] | select(.["container-image-reference"] != $w)
        | .["container-image-reference"] // .origin // "?"' <<<"$status")
    if [[ -z $others ]]; then ok "every deployment is $1 (no rollback to Silverblue or unverified Bazzite)"
    else bad "other deployments left:"; indent <<<"$others"; fi
    local_state=$(jq -r '.deployments[] | select(.booted) | to_entries[]
        | select(.key | test("^(requested-)?(packages|local-packages|base-removals|base-local-replacements|local-fileoverride-packages|modules)$|^initramfs-(args|etc)$"))
        | select((.value // []) | length > 0)
        | select(.key != "initramfs-etc" or .value != [$rule]) | "\(.key): \(.value | tostring)"' \
        --arg rule "$DEGRADED_RULE" <<<"$status")
    local_state+=$'\n'$(jq -r '.deployments[] | select(.booted)
        | (if .["regenerate-initramfs"] == true then "regenerate-initramfs: true\n" else "" end)
        + (if (.unlocked // "none") != "none" then "unlocked: \(.unlocked)\n" else "" end)' <<<"$status")
    if [[ -z ${local_state//[[:space:]]/} ]]; then ok "no layered packages, overrides, initramfs changes or unlock"
    else bad "booted deployment has local changes:"; indent <<<"$local_state"; fi
    # The one deliberate difference: the degraded boot entry's udev rule.
    if jq -e --arg r "$DEGRADED_RULE" '.deployments[] | select(.booted) | (.["initramfs-etc"] // []) | index($r)' \
        <<<"$status" >/dev/null; then ok "initramfs-etc adds $DEGRADED_RULE"
    else bad "initramfs-etc does not track $DEGRADED_RULE"; fi
}

check_image_info() {  # needs BAZZITE_IMAGE, FEDORA_VERSION
    local repo=${BAZZITE_IMAGE%:*} info id
    info=$(vm_ssh cat /usr/share/ublue-os/image-info.json 2>/dev/null || true)
    echo "  image-info: $(jq -c . <<<"$info" 2>/dev/null || echo "${info:-missing}")"
    if jq -e --arg r "ostree-image-signed:docker://$repo" --arg n "${repo##*/}" \
        '.["image-ref"] == $r and .["image-name"] == $n' <<<"$info" >/dev/null 2>&1
    then ok "image-info.json names ${repo##*/} (ostree-image-signed:docker://$repo)"
    else bad "image-info.json does not match $BAZZITE_IMAGE"; fi
    if jq -e --arg v "$FEDORA_VERSION" '.["fedora-version"] == $v' <<<"$info" >/dev/null 2>&1
    then ok "Bazzite is built on Fedora $FEDORA_VERSION"
    else bad "Bazzite's fedora-version is not $FEDORA_VERSION (update FEDORA_VERSION in config.env)"; fi
    # shellcheck disable=SC2016  # expands in the guest
    id=$(vm_ssh '. /etc/os-release && echo "$ID"' || true)
    if [[ $id == bazzite ]]; then ok "os-release ID is bazzite"; else bad "os-release ID is '$id'"; fi
}

# The rebases 3-way merge /etc: a file changed locally (at install time) keeps
# the local version. That differs from a fresh Bazzite install when Bazzite's
# default differs from Silverblue's (M/D), or when the file is Silverblue's and
# Bazzite doesn't ship it at all (A). Local changes to files that both images
# ship identically, and files neither ships, are what any install has.
check_etc_merge() {  # config-diff silverblue-sums bazzite-sums
    local -A sb=() bz=()
    local h p kind before=$CHECK_FAILED
    CHECK_FAILED=0
    while read -r h p; do [[ -n $p ]] && sb[$p]=$h; done < "$2"
    while read -r h p; do [[ -n $p ]] && bz[$p]=$h; done < "$3"
    while read -r kind p; do
        p=${p#./}; p=${p#/}
        [[ -n $p && ! $p =~ $ETC_MERGE_ALLOW ]] || continue
        case $kind in
            A) [[ -z ${sb[$p]+set} ]] || bad "/etc/$p: Silverblue's file kept, Bazzite does not ship it" ;;
            M|D) [[ ${sb[$p]:-absent} == "${bz[$p]:-absent}" ]] \
                   || bad "/etc/$p ($kind): local version kept over Bazzite's different default" ;;
        esac
    done < "$1"
    [[ $CHECK_FAILED == 1 ]] || ok "/etc keeps nothing from Silverblue that a fresh install would not have"
    CHECK_FAILED=$((before | CHECK_FAILED))
}

# The policy the kernel loaded must contain Bazzite's own modules (the ones
# Silverblue doesn't ship): each type they declare must be valid in it. A stale
# Silverblue-compiled policy kept by the /etc merge would fail this.
check_selinux_modules() {  # silverblue-sums bazzite-sums
    local mods out
    mods=$(comm -13 <(selinux_modules "$1") <(selinux_modules "$2"))
    if [[ -z $mods ]]; then ok "Bazzite adds no SELinux modules to check"; return; fi
    # shellcheck disable=SC2016,SC2086  # expands in the guest; one arg per module
    out=$(vm_ssh bash -s -- $mods <<'EOF'
for m in "$@"; do
    f=/usr/etc/selinux/targeted/active/modules/$m/cil
    if [ "$(head -c3 "$f")" = BZh ]; then src=$(bzcat "$f"); else src=$(cat "$f"); fi
    types=$(grep -oE '^\(type [^ )]+\)' <<<"$src" | sed 's/^(type //; s/)$//')
    [ -n "$types" ] || { echo "skip $m"; continue; }
    for t in $types; do
        if printf 'system_u:object_r:%s:s0' "$t" > /sys/fs/selinux/context 2>/dev/null
        then echo "ok $m $t"; else echo "missing $m $t"; fi
    done
done
EOF
    ) || true
    local checked; checked=$(grep -c '^ok ' <<<"$out" || true)
    if grep -q '^missing ' <<<"$out"; then
        bad "loaded SELinux policy lacks types from Bazzite's modules:"
        grep '^missing ' <<<"$out" | indent
    elif [[ $checked -gt 0 ]]; then
        ok "loaded SELinux policy has Bazzite's modules ($checked types from: $(awk '/^ok /{print $2}' <<<"$out" | sort -u | xargs))"
    else
        bad "could not check Bazzite's SELinux modules:"; indent <<<"${out:-no output}"
    fi
}
selinux_modules() {  # sums-file -> "<priority>/<module>" lines
    awk '$2 ~ /^selinux\/targeted\/active\/modules\/[0-9]+\/[^/]+\/cil$/ {
        split($2, a, "/"); print a[5] "/" a[6] }' "$1" | sort -u
}

step_check_bazzite() {
    [[ -f $WORK/silverblue.done ]] || die "run install-silverblue first"
    # shellcheck source=/dev/null
    source "$WORK/config.env"
    local want="ostree-image-signed:docker://$BAZZITE_IMAGE" last="" ref
    local sb_sums=$WORK/silverblue-usr-etc.sums
    boot "$BAZZITE_SERIAL" boot-bazzite
    guest_check bazzite
    ref=$(booted_image || true)
    if [[ $ref == *fedora-silverblue* ]]; then
        vm_ssh test -x /etc/rebase-to-bazzite/rebase.sh || die "rebase script not installed"
        vm_ssh systemctl is-enabled rebase-to-bazzite.service >/dev/null \
            || die "rebase-to-bazzite.service is not enabled"
        # Silverblue's default /etc, for check_etc_merge after the rebase.
        vm_ssh "$USR_ETC_SUMS" > "$sb_sums"
        info "fingerprinted $(wc -l < "$sb_sums") files in Silverblue's /usr/etc"
    fi
    [[ -s $sb_sums ]] || die "no Silverblue /usr/etc fingerprints (booted '$ref'; rerun from prepare)"

    # Finished = signed image booted and the service has deleted itself.
    # shellcheck disable=SC2016  # expands in the guest
    local gone='test ! -e /etc/systemd/system/rebase-to-bazzite.service && test ! -e /etc/rebase-to-bazzite &&
        [ "$(systemctl show -P ActiveState rebase-to-bazzite.service)" = inactive ] && echo gone'
    local deadline=$((SECONDS + REBASE_TIMEOUT_MIN * 60))
    info "waiting for the rebase to $want (timeout ${REBASE_TIMEOUT_MIN} min)"
    while :; do
        ref=$(booted_image || true)
        if [[ -n $ref && $ref != "$last" ]]; then info "booted image: $ref"; last=$ref; fi
        if [[ $ref == "$want" && $(vm_ssh "$gone" 2>/dev/null) == gone ]]; then
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

    info "checks (same as a fresh Bazzite install)"
    check_settled
    vm_ssh cat /proc/cmdline > "$LOGS/bazzite-cmdline.txt" || true
    vm_ssh systemctl list-units --all --no-pager > "$LOGS/bazzite-units.txt" 2>&1 || true
    check_no_leftovers
    check_deployments "$want"
    check_image_info
    vm_ssh ostree admin config-diff > "$LOGS/bazzite-config-diff.txt"
    vm_ssh "$USR_ETC_SUMS" > "$LOGS/bazzite-usr-etc.sums"
    cp "$sb_sums" "$LOGS/"
    check_etc_merge "$LOGS/bazzite-config-diff.txt" "$sb_sums" "$LOGS/bazzite-usr-etc.sums"
    check_selinux_modules "$sb_sums" "$LOGS/bazzite-usr-etc.sums"
    [[ $CHECK_FAILED == 0 ]] || die "Bazzite differs from a fresh install (see above and $LOGS)"
    info "rebase done; matches a fresh Bazzite install"
    stop
}

# --- one SSD dies ----------------------------------------------------------------
# Next boot only: the degraded entry (README.md has the same command).
# shellcheck disable=SC2016  # expands in the guest
BOOT_DEGRADED_ONCE='unshare -m sh -c "test -w /boot/grub2 || mount -o remount,rw /boot
    test -e /boot/grub2/grubenv || grub2-editenv - create
    grub2-editenv - set minipool_boot_once=degraded"'

# Runs in the guest with POOL, BLANK (serial) and DEAD (1|2) prepended. The
# same steps as "If an SSD dies" in README.md.
REBUILD=$(cat <<'EOF'
set -euo pipefail
NEW=/dev/$(lsblk -dno NAME,SERIAL | awk -v s="$BLANK" '$2 == s {print $1}')
[[ $NEW != /dev/ ]] || { echo "blank disk $BLANK not found"; exit 1; }
show=$(btrfs filesystem show "$POOL"); echo "$show"
MEMBER=$(awk '$1 == "devid" && $NF ~ "^/dev/" {print $NF}' <<<"$show")
DEVID=$(awk '$1 == "devid" && tolower($0) ~ /missing/ {print $2}' <<<"$show")
[[ -n $MEMBER && -n $DEVID ]] || { echo "could not tell the surviving member from the missing one"; exit 1; }
MIB=$(( ($(blockdev --getsize64 "$MEMBER") + 1048575) / 1048576 ))
echo "replacing devid $DEVID with a ${MIB} MiB partition on $NEW"
if [[ $DEAD == 2 ]]; then
    echo "size=${MIB}MiB, type=linux" | sfdisk --label gpt "$NEW"
    PART=${NEW}p1
else
    printf 'size=600MiB, type=uefi\nsize=2048MiB, type=linux\nsize=%sMiB, type=linux\n' "$MIB" | sfdisk --label gpt "$NEW"
    PART=${NEW}p3
fi
udevadm settle
btrfs replace start -B "$DEVID" "$PART" "$POOL"
btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft "$POOL"
btrfs scrub start -B "$POOL"
btrfs filesystem show "$POOL"
btrfs filesystem df "$POOL"
EOF
)

check_pool() {  # pool-path degraded|healthy
    local show df other
    show=$(vm_ssh btrfs filesystem show "$1")
    df=$(vm_ssh btrfs filesystem df "$1")
    indent <<<"$show"
    if [[ $2 == degraded ]]; then
        if grep -qi missing <<<"$show"; then ok "pool reports a missing device"
        else bad "pool does not report a missing device"; fi
        return
    fi
    if grep -q "Total devices 2" <<<"$show" && ! grep -qi missing <<<"$show"; then
        ok "pool has 2 devices, none missing"
    else bad "pool is not whole again"; fi
    other=$(grep -E '^(Data|Metadata|System), ' <<<"$df" | grep -v ', RAID1:' || true)
    if [[ -z $other ]] && grep -q '^Data, RAID1:' <<<"$df"; then ok "data, metadata and system are all RAID1"
    else bad "chunks that are not RAID1:"; indent <<<"${other:-$df}"; fi
}

step_degraded() {  # alma|bazzite: the distro whose drive survives
    [[ -f $WORK/silverblue.done ]] || die "run install-silverblue first"
    local who=$1 keep dead pool t=$WORK/degraded-$1 n
    if [[ $who == alma ]]; then keep=$ALMA_SERIAL dead=2 pool=/
    else keep=$BAZZITE_SERIAL dead=1 pool=/var; fi   # Bazzite's / is not the pool; /var is, read-write
    local blank=VMBLANK000$dead
    rm -rf "$t"; mkdir -p "$t"
    for n in 1 2; do qemu-img create -q -f qcow2 -F qcow2 -b "$WORK/disk$n.qcow2" "$t/disk$n.qcow2"; done
    qemu-img create -q -f qcow2 "$t/blank.qcow2" 80G
    cp "$WORK/vars.fd" "$t/vars.fd"
    VARS=$t/vars.fd
    DISKS=("$t/disk1.qcow2:$ALMA_SERIAL" "$t/disk2.qcow2:$BAZZITE_SERIAL")

    boot "$keep" "degraded-$who-1-healthy"
    vm_ssh "$BOOT_DEGRADED_ONCE"
    stop

    DISKS[dead - 1]="$t/blank.qcow2:$blank"
    info "drive $dead swapped for a blank disk"
    boot "$keep" "degraded-$who-2-degraded"
    info "checks (one SSD missing)"
    local cmdline; cmdline=$(vm_ssh cat /proc/cmdline)
    if [[ $cmdline =~ rootflags=([^\ ]*,)?degraded ]]; then ok "booted the degraded entry"
    else bad "booted without degraded: $cmdline"; fi
    if [[ $who == alma ]]; then
        if [[ $(vm_ssh findmnt -no FSROOT /):$(vm_ssh findmnt -no FSROOT /home) == /@alma:/@alma_home ]]
        then ok "/ and /home are mounted"; else bad "/ or /home is not mounted"; fi
    else
        if [[ $(vm_ssh findmnt -no FSROOT /sysroot) == /@bazzite ]]; then ok "/sysroot is mounted"
        else bad "/sysroot is not mounted"; fi
    fi
    check_pool "$pool" degraded
    check_settled
    [[ $CHECK_FAILED == 0 ]] || die "degraded boot of $who failed the checks"

    info "rebuilding the pool onto the blank disk"
    if ! { echo "POOL=$pool BLANK=$blank DEAD=$dead"; echo "$REBUILD"; } \
        | vm_ssh bash -s > "$LOGS/degraded-$who-rebuild.log" 2>&1; then
        indent < "$LOGS/degraded-$who-rebuild.log"
        die "rebuild failed (see $LOGS/degraded-$who-rebuild.log)"
    fi
    indent < "$LOGS/degraded-$who-rebuild.log"
    check_pool "$pool" healthy
    stop

    boot "$keep" "degraded-$who-3-rebuilt"
    info "checks (normal boot after the rebuild)"
    cmdline=$(vm_ssh cat /proc/cmdline)
    if [[ $cmdline =~ degraded ]]; then bad "the degraded entry booted again: $cmdline"
    else ok "the normal entry booted"; fi
    check_pool "$pool" healthy
    check_settled
    [[ $CHECK_FAILED == 0 ]] || die "$who after the rebuild failed the checks"
    stop
    rm -rf "$t"
    info "$who survives drive $dead dying, and the pool is raid1 again"
}

steps=("$@")
[[ ${steps[*]} == all ]] && steps=(prepare install-alma check-alma install-silverblue check-bazzite check-alma
                                   degraded-alma degraded-bazzite)
for s in "${steps[@]}"; do
    case $s in
        prepare)            step_prepare ;;
        install-alma)       install alma ;;
        install-silverblue) [[ -f $WORK/alma.done ]] || die "run install-alma first"; install silverblue ;;
        check-alma)         (step_check_alma) ;;
        check-bazzite)      (step_check_bazzite) ;;
        degraded-alma)      (step_degraded alma) ;;
        degraded-bazzite)   (step_degraded bazzite) ;;
        *) die "unknown step: $s" ;;
    esac
done
