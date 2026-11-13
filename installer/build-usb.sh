#!/usr/bin/env bash
# Build the Alma + Bazzite installer stick with Ventoy.
#
#   ./build-usb.sh --device /dev/sdX      write a USB stick (ERASES it on first run)
#   ./build-usb.sh --render-only DIR      just render kickstarts + ventoy.json into DIR
#
# Downloads (checksum-verified, cached in .cache/): Ventoy, the AlmaLinux boot
# ISO and the Fedora Everything netinstall ISO. Settings come from config.env.
# Re-running on a stick that already has Ventoy only refreshes the files.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.env
source "$HERE/config.env"
CACHE="$HERE/.cache"
mkdir -p "$CACHE"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

DEVICE="" RENDER_DIR="" ALLOW_LOOP=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --device)      DEVICE=${2:?}; shift 2 ;;
        --render-only) RENDER_DIR=${2:?}; shift 2 ;;
        --allow-loop)  ALLOW_LOOP=1; shift ;;   # for building a test image on /dev/loopN
        -h|--help)     usage ;;
        *)             usage 1 ;;
    esac
done
[[ -n $DEVICE || -n $RENDER_DIR ]] || usage 1

if [[ -n $ALMA_DISK_SERIAL && -z $BAZZITE_DISK_SERIAL ]] || [[ -z $ALMA_DISK_SERIAL && -n $BAZZITE_DISK_SERIAL ]]; then
    die "config.env: set both ALMA_DISK_SERIAL and BAZZITE_DISK_SERIAL, or neither"
fi

fetch() {  # url dest
    [[ -f $2 ]] && return 0
    info "downloading ${1##*/}"
    curl -fL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

verify() {  # file expected-sha256
    local got
    got=$(sha256sum "$1" | cut -d' ' -f1)
    if [[ $got != "$2" ]]; then
        rm -f "$1"
        die "checksum mismatch for ${1##*/} (deleted; re-run to download again)"
    fi
    info "verified ${1##*/}"
}

# --- Ventoy -----------------------------------------------------------------
get_ventoy() {
    local base="https://github.com/ventoy/Ventoy/releases/download/v$VENTOY_VERSION"
    local tarball="ventoy-$VENTOY_VERSION-linux.tar.gz"
    VENTOY_DIR="$CACHE/ventoy-$VENTOY_VERSION"
    [[ -x $VENTOY_DIR/Ventoy2Disk.sh ]] && return 0
    rm -f "$CACHE/ventoy-sha256.txt"
    fetch "$base/sha256.txt" "$CACHE/ventoy-sha256.txt"
    fetch "$base/$tarball" "$CACHE/$tarball"
    verify "$CACHE/$tarball" "$(awk -v f="$tarball" '$2==f {print $1}' "$CACHE/ventoy-sha256.txt")"
    tar -xzf "$CACHE/$tarball" -C "$CACHE"
}

# --- AlmaLinux boot ISO -----------------------------------------------------
get_alma() {
    local base="https://repo.almalinux.org/almalinux/$ALMA_MAJOR/isos/x86_64"
    local sums="$CACHE/alma-$ALMA_MAJOR-CHECKSUM"
    rm -f "$sums"
    fetch "$base/CHECKSUM" "$sums"
    ALMA_ISO=$(grep -oE "AlmaLinux-$ALMA_MAJOR\.[0-9]+-x86_64-boot\.iso" "$sums" | sort -V | tail -1)
    [[ -n $ALMA_ISO ]] || die "no AlmaLinux $ALMA_MAJOR boot ISO listed in $base/CHECKSUM"
    [[ -n $RENDER_DIR ]] && return 0   # names are enough for rendering
    fetch "$base/$ALMA_ISO" "$CACHE/$ALMA_ISO"
    verify "$CACHE/$ALMA_ISO" "$(sed -n "s/^SHA256 ($ALMA_ISO) = //p" "$sums")"
}

# --- Fedora Everything netinstall ISO ----------------------------------------
get_fedora() {
    local base="https://dl.fedoraproject.org/pub/fedora/linux/releases/$FEDORA_VERSION/Everything/x86_64/iso"
    local listing sumname sums
    listing=$(curl -fsSL "$base/") || die "Fedora $FEDORA_VERSION not found at $base"
    FEDORA_ISO=$(grep -oE "Fedora-Everything-netinst-x86_64-$FEDORA_VERSION-[0-9.]+\.iso" <<<"$listing" | sort -uV | tail -1)
    sumname=$(grep -oE "Fedora-Everything-$FEDORA_VERSION-[0-9.]+-x86_64-CHECKSUM" <<<"$listing" | sort -uV | tail -1)
    [[ -n $FEDORA_ISO && -n $sumname ]] || die "could not find netinstall ISO/CHECKSUM in $base"
    sums="$CACHE/$sumname"
    fetch "$base/$sumname" "$sums"
    [[ -n $RENDER_DIR ]] && return 0
    fetch "$base/$FEDORA_ISO" "$CACHE/$FEDORA_ISO"
    verify "$CACHE/$FEDORA_ISO" "$(sed -n "s/^SHA256 ($FEDORA_ISO) = //p" "$sums")"
}

# --- Render stick contents ----------------------------------------------------
render() {  # dest-dir
    local out=$1
    mkdir -p "$out/ventoy"
    local ks
    for ks in alma silverblue; do
        sed -e "s|@FEDORA_VERSION@|$FEDORA_VERSION|g" \
            -e "s|@BAZZITE_IMAGE@|$BAZZITE_IMAGE|g" \
            -e "s|@ALMA_DISK_SERIAL@|$ALMA_DISK_SERIAL|g" \
            -e "s|@BAZZITE_DISK_SERIAL@|$BAZZITE_DISK_SERIAL|g" \
            "$HERE/kickstart/$ks.ks" > "$out/ventoy/$ks.ks"
        ! grep -q '@[A-Z_]*@' "$out/ventoy/$ks.ks" || die "unfilled placeholder in $ks.ks"
    done
    cat > "$out/ventoy/ventoy.json" <<EOF
{
  "auto_install": [
    { "image": "/iso/$ALMA_ISO",   "template": ["/ventoy/alma.ks"],       "autosel": 1 },
    { "image": "/iso/$FEDORA_ISO", "template": ["/ventoy/silverblue.ks"], "autosel": 1 }
  ],
  "menu_alias": [
    { "image": "/iso/$ALMA_ISO",   "alias": "Step 1: AlmaLinux Server with GUI  (ERASES BOTH SSDs)" },
    { "image": "/iso/$FEDORA_ISO", "alias": "Step 2: Silverblue -> Bazzite  (drive 2, keeps Alma)" }
  ]
}
EOF
    cp "$HERE/README.md" "$out/README.md"
}

# --- Safety checks on the target stick ---------------------------------------
check_device() {
    [[ -b $DEVICE ]] || die "$DEVICE is not a block device"
    [[ $(lsblk -dno TYPE "$DEVICE") == disk || ( -n $ALLOW_LOOP && $DEVICE == /dev/loop* ) ]] \
        || die "$DEVICE is not a whole disk (give /dev/sdX, not a partition)"
    if [[ $DEVICE != /dev/loop* ]]; then
        local tran rm
        tran=$(lsblk -dno TRAN "$DEVICE" | tr -d ' ')
        rm=$(lsblk -dno RM "$DEVICE" | tr -d ' ')
        [[ $tran == usb || $rm == 1 ]] || die "$DEVICE is not a USB/removable disk - refusing"
    fi
    if lsblk -nro MOUNTPOINTS "$DEVICE" | grep -qE '^/(boot|home)?$'; then
        die "$DEVICE holds a mounted system filesystem - refusing"
    fi
}

part1() { [[ $DEVICE =~ [0-9]$ ]] && echo "${DEVICE}p1" || echo "${DEVICE}1"; }
part2() { [[ $DEVICE =~ [0-9]$ ]] && echo "${DEVICE}p2" || echo "${DEVICE}2"; }

install_ventoy() {
    if [[ $(lsblk -no LABEL "$(part2)" 2>/dev/null) == VTOYEFI ]]; then
        info "$DEVICE already has Ventoy - refreshing files only"
        return
    fi
    echo
    lsblk -o NAME,SIZE,MODEL,TRAN,LABEL,MOUNTPOINTS "$DEVICE"
    echo
    read -rp "Install Ventoy on $DEVICE? EVERYTHING on it is erased. Type the device name (${DEVICE##*/}) to continue: " ans
    [[ $ans == "${DEVICE##*/}" ]] || die "aborted"
    sudo umount "$DEVICE"?* 2>/dev/null || true
    (cd "$VENTOY_DIR" && sudo ./Ventoy2Disk.sh -i -g "$DEVICE")
    sudo udevadm settle
}

copy_to_stick() {
    local mnt staged
    mnt=$(mktemp -d)
    staged=$(mktemp -d)
    trap 'sudo umount "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; rm -rf "$staged"' EXIT
    render "$staged"
    sudo mount "$(part1)" "$mnt"
    sudo mkdir -p "$mnt/iso" "$mnt/ventoy"
    # drop superseded versions of our ISOs, keep anything else on the stick
    local f
    for f in "$mnt"/iso/AlmaLinux-*-x86_64-boot.iso "$mnt"/iso/Fedora-Everything-netinst-*.iso; do
        [[ -e $f ]] || continue
        [[ ${f##*/} == "$ALMA_ISO" || ${f##*/} == "$FEDORA_ISO" ]] || { info "removing old ${f##*/}"; sudo rm -f "$f"; }
    done
    for f in "$ALMA_ISO" "$FEDORA_ISO"; do
        if [[ $(stat -c %s "$mnt/iso/$f" 2>/dev/null) != "$(stat -c %s "$CACHE/$f")" ]]; then
            info "copying $f"
            sudo cp "$CACHE/$f" "$mnt/iso/$f"
        fi
    done
    sudo cp "$staged"/ventoy/* "$mnt/ventoy/"
    sudo cp "$staged/README.md" "$mnt/README.md"
    info "syncing"
    sync
    sudo umount "$mnt"
    info "done - stick is ready"
}

get_alma
get_fedora
if [[ -n $RENDER_DIR ]]; then
    render "$RENDER_DIR"
    info "rendered into $RENDER_DIR"
    exit 0
fi
check_device
get_ventoy
install_ventoy
copy_to_stick
