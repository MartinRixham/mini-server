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
if (cd "$HERE" && shellcheck -x build-usb.sh test-vm.sh tests/test-kickstarts.sh); then
    ok "build-usb.sh test-vm.sh test-kickstarts.sh"
else
    bad "build-usb.sh test-vm.sh test-kickstarts.sh"
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
