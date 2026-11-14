#!/usr/bin/env bash
# Offline tests for the kickstarts (no VM, no root, no downloads).
#
#   tests/test-kickstarts.sh [--out DIR]
#
# - runs each kickstart's %pre against fake disks (fake /sys/block plus stub
#   lsblk/blockdev/blkid) and checks the partitioning it generates or refuses
# - with --out DIR, saves each full kickstart (generated part.ks inlined in
#   place of the %include) as DIR/alma.ks and DIR/silverblue.ks, for
#   ksvalidator. Validate them with the distro's own pykickstart (AlmaLinux
#   patches it to allow btrfs; upstream's RHEL10 handler rejects it), e.g.
#     podman run --rm -v DIR:/ks:z quay.io/almalinuxorg/almalinux:10 \
#       sh -c 'dnf -yq install pykickstart && ksvalidator -v RHEL10 /ks/alma.ks'
# - shellchecks the %pre/%post scripts and the first-boot rebase script
#
# Needs: bash, shellcheck.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=config.env
source "$HERE/config.env"
OUT=""
case ${1:-} in
    --out) OUT=${2:?}; mkdir -p "$OUT" ;;
    "") ;;
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0 FAIL=0
ok()   { echo "  ok: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

ESP_GUID=c12a7328-f81f-11d2-ba4b-00a0c93ec93b

# Render a kickstart the way build-usb.sh does (placeholders from config.env,
# disk serials overridable).
render() {  # name alma-serial bazzite-serial
    sed -e "s|@FEDORA_VERSION@|$FEDORA_VERSION|g" \
        -e "s|@BAZZITE_IMAGE@|$BAZZITE_IMAGE|g" \
        -e "s|@ALMA_DISK_SERIAL@|$2|g" \
        -e "s|@BAZZITE_DISK_SERIAL@|$3|g" \
        -e "/^@DEGRADED_BOOT@\$/{r $HERE/kickstart/degraded-boot.sh" -e 'd' -e '}' \
        "$HERE/kickstart/$1.ks"
}

# Body of the first %pre or %post section.
section() {  # file %pre|%post
    awk -v s="$2" '$1 == s {on = 1; next} on && $1 == "%end" {exit} on' "$1"
}

# --- fake machine --------------------------------------------------------------
# A fresh fake root with stubbed tools. Disks are added with add_disk.
new_machine() {
    M="$WORK/machine.$RANDOM"
    mkdir -p "$M/sys/block" "$M/devices" "$M/disk" "$M/bin"
    : > "$M/blkid"
    cat > "$M/bin/lsblk" <<EOF
#!/bin/bash
# lsblk -dno SERIAL /dev/X  |  lsblk -nro PARTTYPE /dev/X
dev=\${!#}; dev=\${dev#/dev/}
case "\$*" in
    *SERIAL*)   cat "$M/disk/\$dev/serial" ;;
    *PARTTYPE*) cat "$M/disk/\$dev/parttypes" ;;
    *) echo "lsblk stub: unsupported: \$*" >&2; exit 1 ;;
esac
EOF
    cat > "$M/bin/blockdev" <<EOF
#!/bin/bash
# blockdev --getsize64 /dev/X
cat "$M/disk/\${2#/dev/}/bytes"
EOF
    cat > "$M/bin/blkid" <<EOF
#!/bin/bash
# blkid -t LABEL=minipool -o device
cat "$M/blkid"
EOF
    chmod +x "$M"/bin/*
}

add_disk() {  # name size-GiB serial [usb] [removable]
    local name=$1 gib=$2 serial=$3 bus=${4:-pci} removable=${5:-0}
    local real="$M/devices/$bus/$name"
    mkdir -p "$real" "$M/disk/$name"
    echo "$removable" > "$real/removable"
    echo $((gib * 1024 * 1024 * 2)) > "$real/size"       # 512-byte sectors
    ln -s "$real" "$M/sys/block/$name"
    echo $((gib * 1024 * 1024 * 1024)) > "$M/disk/$name/bytes"
    echo "$serial" > "$M/disk/$name/serial"
    : > "$M/disk/$name/parttypes"
}

add_esp()  { echo "$ESP_GUID" >> "$M/disk/$1/parttypes"; }
add_pool() { printf '/dev/%s\n' "$@" > "$M/blkid"; }

# Run a kickstart's %pre on the fake machine. Output part.ks lands in $M/part.ks.
run_pre() {  # ks alma-serial bazzite-serial
    render "$1" "$2" "$3" > "$M/$1.ks"
    section "$M/$1.ks" %pre \
        | sed -e "s|/sys/block|$M/sys/block|g" -e "s|/tmp/part.ks|$M/part.ks|g" \
        > "$M/pre.sh"
    PATH="$M/bin:$PATH" bash "$M/pre.sh" > "$M/pre.log" 2>&1
}

# Full kickstart with the generated part.ks in place of the %include.
assembled() {  # ks
    awk -v inc="$M/part.ks" '
        $1 == "%include" && $2 == "/tmp/part.ks" { while ((getline l < inc) > 0) print l; next }
        { print }' "$M/$1.ks"
}

expect_line() {  # description regex
    if grep -qE -- "$2" "$M/part.ks"; then ok "$1"; else bad "$1 (no line matching '$2')"; cat "$M/part.ks"; fi
}

expect_success() {  # description ks alma-serial bazzite-serial
    if run_pre "$2" "$3" "$4"; then ok "$1"; else bad "$1"; cat "$M/pre.log"; return 1; fi
}

expect_refusal() {  # description message-regex ks alma-serial bazzite-serial
    if run_pre "$3" "$4" "$5"; then
        bad "$1 (%pre succeeded, should have refused)"
    elif grep -qE -- "$2" "$M/pre.log"; then
        ok "$1"
    else
        bad "$1 (refused with the wrong message)"; cat "$M/pre.log"
    fi
}

save() {  # ks
    [[ -z $OUT ]] || assembled "$1" > "$OUT/$1.ks"
}

# Two internal NVMe disks plus the USB installer stick.
standard_machine() {  # size1-GiB size2-GiB
    new_machine
    add_disk nvme0n1 "$1" SER-A
    add_disk nvme1n1 "$2" SER-B
    add_disk sda 16 STICK usb/usb1 1
}

# --- alma.ks -------------------------------------------------------------------
echo "alma.ks %pre"

standard_machine 500 1000
if expect_success "two disks, no serials" alma "" ""; then
    expect_line "only uses the two internal disks" '^ignoredisk --only-use=nvme0n1,nvme1n1$'
    expect_line "boots from drive 1"            '^bootloader --boot-drive=nvme0n1$'
    expect_line "ESP on drive 1"                '^part /boot/efi .*--ondisk=nvme0n1$'
    # 500 GiB = 512000 MiB, minus ESP 600, /boot 2048, slack 16
    expect_line "raid member sized to the smaller disk (drive 1)" '^part btrfs\.01 --size=509336 --ondisk=nvme0n1$'
    expect_line "equal raid member on drive 2"  '^part btrfs\.02 --size=509336 --ondisk=nvme1n1$'
    expect_line "raid1 pool"                    '^btrfs none --data=raid1 --metadata=raid1 --label=minipool '
    expect_line "@alma root subvolume"          '^btrfs / +--subvol --name=@alma +LABEL=minipool$'
    expect_line "@alma_home subvolume"          '^btrfs /home --subvol --name=@alma_home LABEL=minipool$'
    save alma
fi

standard_machine 1000 500
if expect_success "serials pin Alma to the second disk" alma SER-B SER-A; then
    expect_line "boots from the pinned disk" '^bootloader --boot-drive=nvme1n1$'
    expect_line "ESP on the pinned disk"     '^part /boot/efi .*--ondisk=nvme1n1$'
    expect_line "raid member sized to the smaller disk" '^part btrfs\.01 --size=509336 --ondisk=nvme1n1$'
fi

standard_machine 500 500
expect_refusal "unknown serial"      "no internal disk with serial 'NOPE'" alma NOPE SER-A
expect_refusal "same disk for both"  "resolved to the same disk"           alma SER-A SER-A

new_machine; add_disk nvme0n1 500 SER-A; add_disk sda 16 STICK usb/usb1 1
expect_refusal "only one internal disk" "expected exactly 2 internal disks, found 1" alma "" ""

standard_machine 500 500; add_disk nvme2n1 500 SER-C
expect_refusal "three internal disks" "expected exactly 2 internal disks, found 3" alma "" ""

standard_machine 20 500
expect_refusal "disk too small" "disks too small" alma "" ""

# --- silverblue.ks ---------------------------------------------------------------
echo "silverblue.ks %pre"

alma_installed() {  # [esp-disk]
    standard_machine 500 1000
    add_esp "${1:-nvme0n1}"
    add_pool nvme0n1p3 nvme1n1p1
}

alma_installed
if expect_success "after Alma, no serials" silverblue "" ""; then
    expect_line "only uses the two internal disks" '^ignoredisk --only-use=nvme0n1,nvme1n1$'
    expect_line "boots from drive 2"            '^bootloader --boot-drive=nvme1n1$'
    expect_line "ESP on drive 2"                '^part /boot/efi .*--ondisk=nvme1n1$'
    expect_line "/boot on drive 2"              '^part /boot .*--ondisk=nvme1n1$'
    expect_line "@bazzite subvolume in the existing pool" '^btrfs / --subvol --name=@bazzite LABEL=minipool$'
    if grep -qE '^(clearpart|zerombr)' "$M/part.ks"; then bad "does not wipe anything"; else ok "does not wipe anything"; fi
    save silverblue
fi

alma_installed nvme1n1
if expect_success "Alma on the second disk is detected by its ESP" silverblue "" ""; then
    expect_line "boots from the disk without an ESP" '^bootloader --boot-drive=nvme0n1$'
fi

alma_installed
expect_success "serials" silverblue SER-A SER-B && expect_line "boots from the pinned disk" '^bootloader --boot-drive=nvme1n1$'

standard_machine 500 1000; add_esp nvme0n1
expect_refusal "no pool yet" "pool 'minipool' not found on 2 devices \(found 0\)" silverblue "" ""

alma_installed; add_esp nvme1n1
expect_refusal "both disks already have an ESP" "could not tell drives apart" silverblue "" ""

alma_installed; add_esp nvme1n1
expect_refusal "Bazzite already installed (serials given)" "already has an EFI partition" silverblue SER-A SER-B

# --- degraded boot entry ---------------------------------------------------------
echo "degraded-boot-entry"

for ks in alma silverblue; do
    render "$ks" "" "" > "$WORK/$ks.ks"
    if grep -q '@[A-Z_]*@' "$WORK/$ks.ks"; then bad "$ks.ks: unfilled placeholder"; grep -n '@[A-Z_]*@' "$WORK/$ks.ks"
    elif ! section "$WORK/$ks.ks" %post | grep 'systemctl enable minipool-degraded-boot.service' >/dev/null; then
        bad "$ks.ks: %post does not set up the degraded boot entry"
    else ok "$ks.ks %post sets up the degraded boot entry"; fi
done
expect() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
expect "alma.ks puts the udev rule in the initramfs" \
    grep -qF 'install_items+=" /etc/udev/rules.d/65-minipool-degraded.rules "' "$WORK/alma.ks"
# shellcheck disable=SC2016  # literal text in the kickstart
expect "rebase.sh puts the udev rule in the initramfs" \
    grep -qF 'rpm-ostree initramfs-etc --track="$DEGRADED_RULE"' "$WORK/silverblue.ks"

awk "/<<'ENTRYSCRIPT'\$/ {on = 1; next} /^ENTRYSCRIPT\$/ {on = 0} on" "$WORK/alma.ks" > "$WORK/degraded-boot-entry"
chmod +x "$WORK/degraded-boot-entry"

# A fake /boot with BLS entries, plus stubs for grub2-editenv, findmnt, mount.
new_boot() {  # [saved_entry]
    B="$WORK/boot.$RANDOM"
    mkdir -p "$B/loader/entries" "$B/grub2" "$B/bin"
    printf 'saved_entry=%s\n' "${1:-}" > "$B/grubenv"
    printf '#!/bin/bash\ncat %q\n' "$B/grubenv" > "$B/bin/grub2-editenv"
    printf '#!/bin/bash\necho 1234-abcd\n' > "$B/bin/findmnt"
    printf '#!/bin/bash\necho "mount $*" >> %q\n' "$B/mount.log" > "$B/bin/mount"
    chmod +x "$B"/bin/*
}
entry() {  # name, then lines
    local name=$1; shift
    printf '%s\n' "$@" > "$B/loader/entries/$name.conf"
}
run_entry() { PATH="$B/bin:$PATH" MINIPOOL_BOOT=$B "$WORK/degraded-boot-entry" > "$B/out.log" 2>&1; }
cfg_has() {  # description fixed-string
    if grep -qF -- "$2" "$B/grub2/custom.cfg"; then ok "$1"; else bad "$1 (no '$2')"; cat "$B/grub2/custom.cfg"; fi
}
grub_syntax() {
    if ! command -v grub2-script-check >/dev/null; then echo "  (grub2-script-check not installed - GRUB syntax not checked)"; return; fi
    if grub2-script-check "$B/grub2/custom.cfg"; then ok "custom.cfg is valid GRUB script"; else bad "custom.cfg is valid GRUB script"; fi
}

# Alma: saved_entry picks the entry, even when a newer kernel is installed.
new_boot mid-6.12.0-55.el10.x86_64
entry mid-6.12.0-60.el10.x86_64 "title AlmaLinux (6.12.0-60) 10.1" "version 6.12.0-60.el10.x86_64" \
    "linux /vmlinuz-6.12.0-60.el10.x86_64" "options root=UUID=p ro rootflags=subvol=@alma"
entry mid-6.12.0-55.el10.x86_64 "title AlmaLinux (6.12.0-55) 10.1 'Kitten'" "version 6.12.0-55.el10.x86_64" \
    "linux /vmlinuz-6.12.0-55.el10.x86_64" "initrd /initramfs-6.12.0-55.el10.x86_64.img \$tuned_initrd" \
    "options root=UUID=p ro rootflags=subvol=@alma rhgb quiet \$tuned_params" "grub_class almalinux"
entry mid-0-rescue "title AlmaLinux rescue" "version 0-rescue" "linux /vmlinuz-0-rescue" "options root=UUID=p"
# shellcheck disable=SC2016  # the $... below are GRUB variables, kept literally
if run_entry; then
    ok "Alma-style entries"
    cfg_has "copies the saved_entry kernel" 'linux /vmlinuz-6.12.0-55.el10.x86_64 root=UUID=p ro rootflags=subvol=@alma,degraded rhgb quiet $tuned_params'
    cfg_has "copies the initrd"            '  initrd /initramfs-6.12.0-55.el10.x86_64.img $tuned_initrd'
    cfg_has "quotes the title"             "menuentry 'AlmaLinux (6.12.0-55) 10.1 '\''Kitten'\'' - one SSD missing (degraded)' --id minipool-degraded {"
    cfg_has "finds /boot by UUID"          'search --no-floppy --fs-uuid --set=root 1234-abcd'
    cfg_has "boot-once switch"             'if [ "${minipool_boot_once}" = degraded ]; then'
    grub_syntax
    if [[ ! -e $B/mount.log ]]; then ok "no remount when /boot is writable"; else bad "remounted a writable /boot"; fi
    before=$(stat -c %Y.%i "$B/grub2/custom.cfg")
    if run_entry && [[ $(stat -c %Y.%i "$B/grub2/custom.cfg") == "$before" && ! -s $B/out.log ]]; then
        ok "unchanged entry is not rewritten"
    else bad "unchanged entry is not rewritten"; fi
    rm "$B/loader/entries/mid-6.12.0-55.el10.x86_64.conf"
    run_entry && cfg_has "falls back to the newest kernel when saved_entry is gone" 'linux /vmlinuz-6.12.0-60.el10.x86_64 '
else
    bad "Alma-style entries"; cat "$B/out.log"
fi

# ostree: no saved_entry; the highest version is the default deployment.
new_boot
entry ostree-1 "title Fedora Linux 45 (ostree:1)" "version 1" "linux /ostree/default-old/vmlinuz" \
    "initrd /ostree/default-old/initramfs.img" "options root=UUID=p rootflags=subvol=@bazzite ostree=/ostree/boot.1/default/old/0"
entry ostree-2 "title Fedora Linux 45 (ostree:0)" "version 2" "linux /ostree/default-new/vmlinuz" \
    "initrd /ostree/default-new/initramfs.img" "initrd /ostree/initramfs-overlays/abc.img" \
    "options root=UUID=p rootflags=subvol=@bazzite ostree=/ostree/boot.1/default/new/0"
if run_entry; then
    ok "ostree-style entries"
    cfg_has "copies the newest deployment" 'linux /ostree/default-new/vmlinuz root=UUID=p rootflags=subvol=@bazzite,degraded ostree=/ostree/boot.1/default/new/0'
    cfg_has "joins initrd lines"           '  initrd /ostree/default-new/initramfs.img /ostree/initramfs-overlays/abc.img'
    grub_syntax
else
    bad "ostree-style entries"; cat "$B/out.log"
fi

new_boot
entry plain "title Plain" "version 1" "linux /vmlinuz" "options root=LABEL=minipool ro"
if run_entry; then cfg_has "adds rootflags=degraded when there is none" 'linux /vmlinuz root=LABEL=minipool ro rootflags=degraded'
else bad "entry without rootflags"; cat "$B/out.log"; fi
if grep -q initrd "$B/grub2/custom.cfg"; then bad "no initrd line when the entry has none"; else ok "no initrd line when the entry has none"; fi
grub_syntax

new_boot
entry plain "title Plain" "version 1" "linux /vmlinuz" "options ro"
echo "menuentry mine {}" > "$B/grub2/custom.cfg"
if run_entry && [[ $(cat "$B/grub2/custom.cfg") == "menuentry mine {}" ]]; then
    ok "leaves a custom.cfg it did not write alone"
else bad "leaves a custom.cfg it did not write alone"; fi

new_boot
if run_entry; then bad "fails without boot entries"; else ok "fails without boot entries"; fi

# --- minipool-rebuild ------------------------------------------------------------
echo "minipool-rebuild"
awk "/<<'REBUILDSCRIPT'\$/ {on = 1; next} /^REBUILDSCRIPT\$/ {on = 0} on" "$WORK/alma.ks" > "$WORK/minipool-rebuild"
awk "/<<'NOTICESCRIPT'\$/ {on = 1; next} /^NOTICESCRIPT\$/ {on = 0} on" "$WORK/alma.ks" > "$WORK/degraded-notice"
chmod +x "$WORK/minipool-rebuild" "$WORK/degraded-notice"
expect "%post links minipool-rebuild into /usr/local/sbin" \
    grep -qxF 'L /usr/local/sbin/minipool-rebuild - - - - /etc/minipool/rebuild' "$WORK/alma.ks"

# A fake server with one SSD gone: stub findmnt/btrfs/lsblk/blockdev/wipefs,
# with sfdisk and btrfs writes logged. Disks are added with rdisk.
GIB=1073741824
new_server() {  # alma|bazzite
    R="$WORK/server.$RANDOM"
    mkdir -p "$R/bin" "$R/disks" "$R/sys/class/block"
    : > "$R/log"
    local keep member part pool
    if [[ $1 == alma ]]; then keep=nvme0n1 part=3 pool=/;    echo ID=almalinux > "$R/os-release"
    else                      keep=nvme1n1 part=1 pool=/var; echo ID=bazzite > "$R/os-release"; fi
    member=${keep}p$part
    echo "$pool btrfs minipool rw,relatime" > "$R/mounts"
    mkdir -p "$R/sys/class/block/$member"; echo "$part" > "$R/sys/class/block/$member/partition"
    rdisk "$keep" 100 SSD-KEEP; echo "$member" >> "$R/disks/$keep/children"; echo minipool > "$R/disks/$keep/labels"
    echo "$keep" > "$R/parent.$member"
    cat > "$R/show" <<EOF
Label: 'minipool'  uuid: 0000
	Total devices 2 FS bytes used 1.00GiB
	devid    1 size $((50 * GIB)) used $((2 * GIB)) path /dev/$member
	devid    2 size $((50 * GIB)) used $((2 * GIB)) path <missing disk> MISSING
EOF
    printf 'Data, single: total=1.00GiB, used=0.50GiB\nData, RAID1: total=1.00GiB, used=0.50GiB\n' > "$R/df"
    cat > "$R/bin/findmnt" <<EOF
#!/bin/bash
awk -v p="\${@: -1}" '\$1 == p {print \$2, \$3, \$4}' $R/mounts
EOF
    cat > "$R/bin/btrfs" <<EOF
#!/bin/bash
case "\$1 \$2" in
    "filesystem show") cat $R/show ;;
    "filesystem df")   cat $R/df ;;
    "replace status")  echo "Never started" ;;
    *) echo "btrfs \$*" >> $R/log ;;
esac
EOF
    cat > "$R/bin/lsblk" <<EOF
#!/bin/bash
D=$R/disks
cols="" dev=""
for a in "\$@"; do case \$a in -*) ;; *) if [[ -z \$cols ]]; then cols=\$a; else dev=\${a#/dev/}; fi ;; esac; done
case \$cols in
    PKNAME)            cat $R/parent.\$dev ;;
    NAME)              if [[ -z \$dev ]]; then for d in \$D/*; do echo /dev/\${d##*/}; done
                       else echo \$dev; cat \$D/\$dev/children 2>/dev/null; fi ;;
    SIZE,MODEL,SERIAL) echo "\$(cat \$D/\$dev/gib)G Test-SSD \$(cat \$D/\$dev/serial)" ;;
    SIZE,RM,TYPE,TRAN) echo "\$(( \$(cat \$D/\$dev/gib) * $GIB )) \$(cat \$D/\$dev/rm) \$(cat \$D/\$dev/type) \$(cat \$D/\$dev/tran)" ;;
    LABEL)             cat \$D/\$dev/labels 2>/dev/null || true ;;
    *) echo "lsblk stub: unknown \$*" >&2; exit 1 ;;
esac
EOF
    printf '#!/bin/bash\necho %s\n' "$((50 * GIB))" > "$R/bin/blockdev"
    # shellcheck disable=SC2016  # expands in the stub
    printf '#!/bin/bash\ncat %q/disks/${2#/dev/}/sigs 2>/dev/null || true\n' "$R" > "$R/bin/wipefs"
    printf '#!/bin/bash\n{ echo "sfdisk $*"; cat; } >> %q/log\n' "$R" > "$R/bin/sfdisk"
    # shellcheck disable=SC2016  # expands in the stub
    printf '#!/bin/bash\necho "${@: -1}"\n' > "$R/bin/realpath"
    printf '#!/bin/bash\n' > "$R/bin/udevadm"
    chmod +x "$R"/bin/*
}
rdisk() {  # name size-GiB serial [type] [tran] [rm]
    mkdir -p "$R/disks/$1"
    echo "$2" > "$R/disks/$1/gib"; echo "$3" > "$R/disks/$1/serial"
    echo "${4:-disk}" > "$R/disks/$1/type"; echo "${5:-nvme}" > "$R/disks/$1/tran"; echo "${6:-0}" > "$R/disks/$1/rm"
}
rebuild() {  # answer, then args
    local answer=$1; shift
    echo "$answer" | PATH="$R/bin:$PATH" MINIPOOL_SYS=$R/sys MINIPOOL_OS_RELEASE=$R/os-release \
        "$WORK/minipool-rebuild" "$@" > "$R/out" 2>&1
}
said() {  # description fixed-string
    if grep -qF -- "$2" "$R/out"; then ok "$1"; else bad "$1 (no '$2')"; sed 's/^/    /' "$R/out"; fi
}
untouched() {  # description
    if grep -q sfdisk "$R/log"; then bad "$1: partitioned a disk"; else ok "$1: no disk touched"; fi
}

new_server alma
rdisk nvme1n1 100 SSD-NEW; rdisk sda 32 STICK disk usb 1; rdisk zram0 8 "" disk ""
if rebuild no; then bad "answering no fails"; else ok "answering no fails"; fi
said "Alma: the one blank internal disk is picked" "The new SSD:     /dev/nvme1n1"
said "Alma: rebuilds drive 2" "running AlmaLinux, so drive 2 is the one to rebuild"
said "says which devid it replaces" "btrfs replace of missing devid 2"
untouched "answer no"
rebuild yes || true
if grep -qxF "size=51200MiB, type=linux" "$R/log" && grep -qF "sfdisk --label gpt /dev/nvme1n1" "$R/log"; then
    ok "drive 2: one pool member partition the size of the survivor"
else bad "drive 2 partitioning"; cat "$R/log"; fi

new_server bazzite
rdisk nvme0n1 100 SSD-NEW
rebuild yes || true
said "Bazzite: pool at /var, rebuilds drive 1" "mounted at /var; running Bazzite, so drive 1 is the one to rebuild"
if [[ $(grep -A3 'sfdisk --label gpt /dev/nvme0n1' "$R/log" | tail -3) == $'size=600MiB, type=uefi\nsize=2048MiB, type=linux\nsize=51200MiB, type=linux' ]]; then
    ok "drive 1: ESP, /boot and pool member"
else bad "drive 1 partitioning"; cat "$R/log"; fi

new_server alma
rdisk nvme1n1 100 SSD-A; rdisk nvme2n1 100 SSD-B
if rebuild yes; then bad "two blank disks: refuses"; else said "two blank disks: refuses" "pick one with --disk"; fi
untouched "two blank disks"
rebuild no --disk /dev/nvme2n1 || true
said "--disk picks one of them" "The new SSD:     /dev/nvme2n1"

new_server alma
rdisk nvme1n1 100 SSD-OLD; echo minipool > "$R/disks/nvme1n1/labels"; echo nvme1n1p1 > "$R/disks/nvme1n1/children"
if rebuild yes; then bad "old SSD put back: refuses"; else said "old SSD put back: refuses" "the old SSD? Don't reuse it"; fi
untouched "old SSD"
rebuild yes --disk /dev/nvme1n1 || true
said "old SSD refused with --disk too" "/dev/nvme1n1 can't be the new SSD"
untouched "old SSD with --disk"

new_server alma
rdisk nvme1n1 100 SSD-USED; echo "0x438 btrfs" > "$R/disks/nvme1n1/sigs"
rebuild yes || true
said "a disk with a filesystem is not blank" "not blank (wipe it with 'wipefs -a /dev/nvme1n1'"
untouched "not blank"

new_server alma
rdisk nvme1n1 52 SSD-SMALL
rebuild yes || true
said "too small for the pool member plus ESP and /boot" "too small (53248 MiB, needs 53864)"
untouched "too small"

new_server alma
rdisk sda 200 USB-DISK disk usb 0
rebuild yes || true
said "USB disks are never picked" "/dev/sda (200G Test-SSD USB-DISK): removable or USB"
untouched "USB disk"

new_server alma
sed -i 's/<missing disk> MISSING/\/dev\/nvme1n1p1/' "$R/show"; sed -i '/single/d' "$R/df"
if rebuild yes; then said "whole pool: nothing to do" "nothing to do"; else bad "whole pool: nothing to do"; cat "$R/out"; fi

new_server alma
sed -i 's/<missing disk> MISSING/\/dev\/nvme1n1p1/' "$R/show"
rebuild yes || true
said "interrupted after replace: balances" "some chunks are not RAID1"
if grep -qF "btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft /" "$R/log"; then ok "runs the balance"
else bad "runs the balance"; cat "$R/log"; fi

# The notice: written while degraded, removed once whole (paths redirected).
sed -e "s|/run/motd.d|$WORK/run/motd.d|; s|/run/issue.d|$WORK/run/issue.d|" "$WORK/degraded-notice" > "$WORK/notice-test"
new_server alma
if PATH="$R/bin:$PATH" bash "$WORK/notice-test" > /dev/null && grep -q "sudo minipool-rebuild" "$WORK/run/motd.d/90-minipool" \
    && grep -q "missing an SSD" "$WORK/run/issue.d/90-minipool.issue"; then ok "notice while degraded"
else bad "notice while degraded"; fi
sed -i 's/<missing disk> MISSING/\/dev\/nvme1n1p1/' "$R/show"; sed -i '/single/d' "$R/df"
if PATH="$R/bin:$PATH" bash "$WORK/notice-test" > /dev/null && [[ ! -e $WORK/run/motd.d/90-minipool ]]; then ok "notice removed once whole"
else bad "notice removed once whole"; fi

# --- shellcheck ----------------------------------------------------------------
echo "shellcheck"
for ks in alma silverblue; do
    render "$ks" "" "" > "$WORK/$ks.ks"
    for s in %pre %post; do
        body=$(section "$WORK/$ks.ks" "$s")
        [[ -n $body ]] || continue
        # SC2034: settings like ALMA_SERIAL are intentionally always defined
        if { echo '#!/bin/bash'; echo "$body"; } | shellcheck -s bash -e SC2034 - ; then
            ok "$ks.ks $s"
        else
            bad "$ks.ks $s"
        fi
    done
done
awk '/<<.SCRIPT.$/ {on = 1; next} /^SCRIPT$/ {on = 0} on' "$WORK/silverblue.ks" > "$WORK/rebase.sh"
if shellcheck -s bash "$WORK/rebase.sh"; then ok "rebase.sh"; else bad "rebase.sh"; fi
for f in degraded-boot-entry minipool-rebuild degraded-notice; do
    if shellcheck -s bash "$WORK/$f"; then ok "$f"; else bad "$f"; fi
done
if (cd "$HERE" && shellcheck -x build-usb.sh test-vm.sh tests/*.sh); then
    ok "build-usb.sh test-vm.sh tests/*.sh"
else
    bad "build-usb.sh test-vm.sh tests/*.sh"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
