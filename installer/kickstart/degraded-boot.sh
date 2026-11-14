# ---- degraded boot entry and rebuild (from kickstart/degraded-boot.sh) ------
# Shared %post fragment for both kickstarts; build-usb.sh pastes it in place of
# the DEGRADED_BOOT placeholder line. Lets either distro boot with one SSD missing:
#
# - a udev rule: systemd's 64-btrfs.rules marks the pool "not ready" until every
#   member is present, so with one dead SSD nothing waiting for the root device
#   ever starts. This rule marks it ready anyway, but only when the kernel
#   command line has "degraded" in rootflags=. Each kickstart also puts the rule
#   in the initramfs (Alma: dracut.conf.d; Bazzite: rpm-ostree initramfs-etc).
# - a boot menu entry "... - one SSD missing (degraded)": a copy of the default
#   entry with ",degraded" added to rootflags=, kept in /boot/grub2/custom.cfg
#   (sourced by Alma's grub.cfg and by Fedora's static one) and rewritten at
#   every boot and shutdown, so it follows kernel and ostree updates.

mkdir -p /etc/udev/rules.d /etc/minipool /etc/systemd/system

cat > /etc/udev/rules.d/65-minipool-degraded.rules <<'RULES'
# Booted with rootflags=...degraded: let systemd use the "minipool" btrfs pool
# even while a member is missing (64-btrfs.rules would hold it back forever).
SUBSYSTEM!="block", GOTO="minipool_degraded_end"
ACTION=="remove", GOTO="minipool_degraded_end"
ENV{ID_FS_TYPE}!="btrfs", GOTO="minipool_degraded_end"
ENV{ID_FS_LABEL}!="minipool", GOTO="minipool_degraded_end"
IMPORT{cmdline}="rootflags"
ENV{rootflags}=="*degraded*", ENV{SYSTEMD_READY}="1"
LABEL="minipool_degraded_end"
RULES

cat > /etc/minipool/degraded-boot-entry <<'ENTRYSCRIPT'
#!/bin/bash
# Writes /boot/grub2/custom.cfg with a "one SSD missing (degraded)" menu entry:
# the default boot entry with ",degraded" added to rootflags=. Run at boot and
# at shutdown (after ostree has written a staged update's entries) by
# minipool-degraded-boot.service. To pick the entry for the next boot only:
#   grub2-editenv - set minipool_boot_once=degraded
set -euo pipefail
shopt -s nullglob
BOOT=${MINIPOOL_BOOT:-/boot}   # overridable for tests/test-kickstarts.sh
ENTRIES=$BOOT/loader/entries
CFG=$BOOT/grub2/custom.cfg
MARK="# minipool degraded boot entry"

die() { echo "degraded-boot-entry: $*" >&2; exit 1; }

if [[ -e $CFG ]] && ! grep -qxF "$MARK" "$CFG"; then
    echo "degraded-boot-entry: $CFG was not written by this script - leaving it alone" >&2
    exit 0
fi

# The entry GRUB boots by default: saved_entry if it names one (Alma), else
# the newest (ostree: the highest version is deployment 0).
saved=$(grub2-editenv "$BOOT/grub2/grubenv" list 2>/dev/null | sed -n 's/^saved_entry=//p' || true)
if [[ -n $saved && -f $ENTRIES/$saved.conf ]]; then
    entry=$ENTRIES/$saved.conf
else
    entry=$(for f in "$ENTRIES"/*.conf; do
                [[ $f == *rescue* ]] && continue
                printf '%s\t%s\n' "$(awk '$1 == "version" {print $2; exit}' "$f")" "$f"
            done | sort -V -r | head -1 | cut -f2)
fi
[[ -n $entry ]] || die "no boot entries in $ENTRIES"

field() { awk -v k="$1" '$1 == k { sub(/^[^ \t]+[ \t]+/, ""); print }' "$entry"; }
title=$(field title | head -1)
linux=$(field linux | head -1)
initrd=$(field initrd | paste -sd ' ')
[[ -n $linux ]] || die "$entry has no linux line"

opts="" found=""
set -f
for o in $(field options); do
    case $o in rootflags=*) o+=",degraded"; found=1 ;; esac
    opts+=" $o"
done
set +f
[[ -n $found ]] || opts+=" rootflags=degraded"

uuid=$(findmnt -no UUID "$BOOT")
[[ -n $uuid ]] || die "no filesystem UUID for $BOOT"
quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

new=$(cat <<EOF
$MARK
# Written by /etc/minipool/degraded-boot-entry at every boot and shutdown;
# edits are lost. Copied from ${entry##*/}.
if [ "\${minipool_boot_once}" = degraded ]; then
  set default=minipool-degraded
  set minipool_boot_once=
  save_env minipool_boot_once
fi
menuentry $(quote "${title:-Linux} - one SSD missing (degraded)") --id minipool-degraded {
  insmod part_gpt
  insmod ext2
  search --no-floppy --fs-uuid --set=root $uuid
  linux $linux$opts
${initrd:+  initrd $initrd
}}
EOF
)

[[ $new != "$(cat "$CFG" 2>/dev/null)" ]] || exit 0
# ostree mounts /boot read-only; the unit runs this in its own mount namespace.
[[ -w ${CFG%/*} ]] || mount -o remount,rw "$BOOT"
printf '%s\n' "$new" > "$CFG.tmp"
mv "$CFG.tmp" "$CFG"
echo "degraded boot entry now copies ${entry##*/}: $title"
ENTRYSCRIPT
chmod 0755 /etc/minipool/degraded-boot-entry

cat > /etc/systemd/system/minipool-degraded-boot.service <<'UNIT'
[Unit]
Description=Keep the "one SSD missing (degraded)" boot entry in step with the default
DefaultDependencies=no
RequiresMountsFor=/boot
After=local-fs.target
# Stopping runs after ostree-finalize-staged has written a staged update's
# boot entries, so the entry follows the update before its first boot.
Before=ostree-finalize-staged.service basic.target final.target
Conflicts=final.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/unshare -m /etc/minipool/degraded-boot-entry
ExecStop=/usr/bin/unshare -m /etc/minipool/degraded-boot-entry

[Install]
WantedBy=multi-user.target
UNIT

systemctl enable minipool-degraded-boot.service

# ---- rebuilding the pool onto a new SSD ---------------------------------------
# - /etc/minipool/rebuild (run as "sudo minipool-rebuild"): the README's "Rebuild
#   the pool onto the new SSD" steps, run on whichever distro survived. It picks
#   the new SSD only if it is the one blank internal disk, and asks first.
# - /etc/minipool/degraded-notice: at every boot, a login and console notice
#   while the pool is missing a member or is not all RAID1.
# The command is a tmpfiles.d symlink because on ostree /usr/local is in /var,
# which is not populated at install time.

cat > /etc/minipool/rebuild <<'REBUILDSCRIPT'
#!/bin/bash
# minipool-rebuild [--disk /dev/X]
#
# Rebuilds the "minipool" btrfs raid1 pool onto a new SSD after one died, from
# whichever distro survived: partitions the new SSD like the drive it replaces,
# copies the pool onto it (btrfs replace), makes everything written while
# degraded RAID1 again (balance) and checks every copy (scrub). Safe to run
# again if it was interrupted. It does not make the other distro bootable
# again; it prints how at the end.
#
# The new SSD must be blank (no partition table, no filesystem). Without
# --disk, it must be the only blank internal disk. Asks before erasing it.
set -euo pipefail

LABEL=minipool
ESP_MIB=600 BOOT_MIB=2048 SLACK_MIB=16   # as in the kickstarts
SYS=${MINIPOOL_SYS:-/sys} OS_RELEASE=${MINIPOOL_OS_RELEASE:-/etc/os-release}   # for tests/test-kickstarts.sh

die()  { echo "minipool-rebuild: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
usage() { sed -n '2,12s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

DISK=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --disk) DISK=${2:?--disk needs a device}; shift 2 ;;
        -h|--help) usage ;;
        *) usage 1 >&2 ;;
    esac
done
[[ $EUID == 0 || -n ${MINIPOOL_SYS:-} ]] || die "run it as root: sudo minipool-rebuild"

# A writable mount of the pool: / on Alma, /var on Bazzite (whose / is not it).
POOL=""
for p in / /var; do
    fstype="" label="" opts=""
    read -r fstype label opts < <(findmnt -rn -o FSTYPE,LABEL,OPTIONS --mountpoint "$p" || true) || true
    if [[ ${fstype:-} == btrfs && ${label:-} == "$LABEL" && ,${opts:-}, == *,rw,* ]]; then POOL=$p; break; fi
done
[[ -n $POOL ]] || die "the $LABEL pool is not mounted read-write at / or /var"

# shellcheck source=/dev/null
ID=$(. "$OS_RELEASE" && echo "$ID")
case $ID in
    almalinux) SURVIVOR=AlmaLinux DEAD=2 ;;   # Alma boots from drive 1
    *)         SURVIVOR=Bazzite   DEAD=1 ;;   # Bazzite boots from drive 2
esac

show() { btrfs filesystem show "$@" "$POOL"; }
missing() { show | grep -i missing >/dev/null; }
not_raid1() { btrfs filesystem df "$POOL" | grep -E '^(Data|Metadata|System), ' | grep -v ', RAID1:' || true; }
replace_running() { btrfs replace status -1 "$POOL" 2>/dev/null | grep -q '% done'; }

next_steps() {
    echo
    if [[ $DEAD == 1 ]]; then
        echo "The pool is whole again. AlmaLinux can't boot yet: its ESP and /boot on"
        echo "${NEW:-the new SSD} are still empty. See \"3. Get the other distro booting again\""
        echo "in the mini-server README (AlmaLinux, drive 1 died)."
    else
        echo "The pool is whole again. Bazzite can't boot yet: reinstall it with Step 2"
        echo "of the installer. See \"3. Get the other distro booting again\" in the"
        echo "mini-server README (Bazzite, drive 2 died)."
    fi
    echo "Reboot first: $SURVIVOR now boots from its normal entry."
}

finish() {  # balance what was written while degraded, then scrub
    step "making everything RAID1 again (btrfs balance)"
    btrfs balance start -dconvert=raid1,soft -mconvert=raid1,soft "$POOL"
    step "checking every copy (btrfs scrub, can take a while)"
    btrfs scrub start -B "$POOL"
    btrfs filesystem df "$POOL"
    [[ -z $(not_raid1) ]] || die "some chunks are still not RAID1 - see above"
    /etc/minipool/degraded-notice || true
    next_steps
}

wait_replace() {
    step "copying the pool onto the new SSD (btrfs replace) - this takes a while"
    echo "It carries on in the kernel if this session is lost; run minipool-rebuild again to follow it."
    btrfs replace status "$POOL"
    if missing; then
        btrfs replace status -1 "$POOL" || true
        die "btrfs replace did not finish - see above"
    fi
}

echo "pool: $LABEL, mounted at $POOL; running $SURVIVOR, so drive $DEAD is the one to rebuild"
show

if replace_running; then
    wait_replace
    finish
    exit 0
fi
if ! missing; then
    if [[ -n $(not_raid1) ]]; then
        echo "No member is missing, but some chunks are not RAID1:"; not_raid1
        finish
        exit 0
    fi
    echo "The pool is whole and all RAID1 - nothing to do."
    exit 0
fi

# --- what to replace ------------------------------------------------------------
DEVID=$(show | awk '$1 == "devid" && tolower($0) ~ /missing/ {print $2}')
MEMBER=$(show | awk '$1 == "devid" && $NF ~ "^/dev/" {print $NF}')
[[ $(wc -w <<<"$DEVID") == 1 && $(wc -w <<<"$MEMBER") == 1 ]] \
    || die "expected one missing member and one present - not the layout the installer makes, so not rebuilding it automatically"
KEEP=/dev/$(lsblk -no PKNAME "$MEMBER")
partno=$(cat "$SYS/class/block/${MEMBER##*/}/partition")
want=$([[ $DEAD == 2 ]] && echo 3 || echo 1)   # pool member: drive 1 part 3, drive 2 part 1
[[ $partno == "$want" ]] \
    || die "the surviving member $MEMBER is partition $partno, expected $want for drive $((3 - DEAD)) - not the layout the installer makes, so not rebuilding it automatically"

# The new member must be at least as big as the old one; both match the survivor.
bytes=$(blockdev --getsize64 "$MEMBER")
lost=$(show --raw | awk -v d="$DEVID" '$1 == "devid" && $2 == d {print $4}')
[[ ${lost:-0} =~ ^[0-9]+$ && ${lost:-0} -gt $bytes ]] && bytes=$lost
MIB=$(( (bytes + 1048575) / 1048576 ))
# Room for the pool member plus an ESP and /boot (drive 1's own, or the space
# Bazzite's reinstall needs on drive 2).
NEED_MIB=$(( MIB + ESP_MIB + BOOT_MIB + SLACK_MIB ))

# --- the new SSD ----------------------------------------------------------------
describe() { lsblk -dno SIZE,MODEL,SERIAL "$1" | tr -s ' '; }
blank() {  # disk: no partitions and no signatures
    [[ $(lsblk -nro NAME "$1" | wc -l) == 1 && -z $(wipefs --noheadings "$1" 2>/dev/null) ]]
}
why_not() {  # disk -> reason it can't be the new SSD, or nothing
    local d=$1 name=${1##*/} size="" rm="" type="" tran=""
    read -r size rm type tran < <(lsblk -dnbro SIZE,RM,TYPE,TRAN "$d")   # TRAN may be empty: last
    case $name in loop*|ram*|zram*|sr*|dm-*|md*|nbd*|fd*) echo "not a physical disk"; return ;; esac
    [[ $type == disk ]] || { echo "not a disk ($type)"; return; }
    [[ $d == "$KEEP" ]] && { echo "the surviving SSD"; return; }
    [[ $rm == 0 && $tran != usb ]] || { echo "removable or USB"; return; }
    if lsblk -nro LABEL "$d" | grep -qxF "$LABEL"; then
        echo "has a $LABEL pool member - the old SSD? Don't reuse it: its copy is out of date"; return
    fi
    blank "$d" || { echo "not blank (wipe it with 'wipefs -a $d' if you are sure)"; return; }
    (( size / 1048576 >= NEED_MIB )) || { echo "too small ($(( size / 1048576 )) MiB, needs $NEED_MIB)"; return; }
}

if [[ -n $DISK ]]; then
    DISK=$(realpath -e "$DISK") || die "no such device: $DISK"
    reason=$(why_not "$DISK")
    [[ -z $reason ]] || die "$DISK can't be the new SSD: $reason"
    NEW=$DISK
else
    cands=() report=""
    for d in $(lsblk -dnpro NAME); do
        reason=$(why_not "$d")
        if [[ -z $reason ]]; then cands+=("$d"); fi
        report+="  $d ($(describe "$d")): ${reason:-blank, big enough}"$'\n'
    done
    if [[ ${#cands[@]} != 1 ]]; then
        echo "Disks:"; printf '%s' "$report"
        if [[ ${#cands[@]} == 0 ]]; then
            die "no blank internal disk of at least $NEED_MIB MiB - is the new SSD in?"
        fi
        die "more than one could be the new SSD - pick one with --disk"
    fi
    NEW=${cands[0]}
fi

if [[ $DEAD == 1 ]]; then
    layout="ESP ${ESP_MIB} MiB, /boot ${BOOT_MIB} MiB (both left empty), pool member ${MIB} MiB"
    PARTNO=3
else
    layout="pool member ${MIB} MiB, the rest left free for Bazzite"
    PARTNO=1
fi
cat <<EOF

The new SSD:     $NEW  ($(describe "$NEW"))
Surviving SSD:   $KEEP  ($(describe "$KEEP")), not touched
New layout:      $layout
Then:            btrfs replace of missing devid $DEVID, balance to RAID1, scrub

EOF
read -r -p "This ERASES $NEW. Type yes to go on: " answer
[[ $answer == yes ]] || die "stopped, nothing changed"

# --- rebuild --------------------------------------------------------------------
step "partitioning $NEW"
if [[ $DEAD == 1 ]]; then
    printf 'size=%sMiB, type=uefi\nsize=%sMiB, type=linux\nsize=%sMiB, type=linux\n' \
        "$ESP_MIB" "$BOOT_MIB" "$MIB" | sfdisk --label gpt "$NEW"
else
    echo "size=${MIB}MiB, type=linux" | sfdisk --label gpt "$NEW"
fi
udevadm settle
PART=$NEW$([[ $NEW =~ [0-9]$ ]] && echo p)$PARTNO
[[ -b $PART ]] || die "$PART did not appear after partitioning"

btrfs replace start "$DEVID" "$PART" "$POOL"
wait_replace
show
finish
REBUILDSCRIPT
chmod 0755 /etc/minipool/rebuild

cat > /etc/minipool/degraded-notice <<'NOTICESCRIPT'
#!/bin/bash
# Writes a notice for logins (motd) and the console (issue) while the minipool
# pool is missing a member or has chunks that are not RAID1; removes it once
# the pool is whole. Run at boot by minipool-degraded-notice.service and at the
# end of minipool-rebuild.
set -euo pipefail
LABEL=minipool
MOTD=/run/motd.d/90-minipool
ISSUE=/run/issue.d/90-minipool.issue

pool=""
for p in / /var; do
    fstype="" label=""
    read -r fstype label _ < <(findmnt -rn -o FSTYPE,LABEL --mountpoint "$p" || true) || true
    if [[ ${fstype:-} == btrfs && ${label:-} == "$LABEL" ]]; then pool=$p; break; fi
done
[[ -n $pool ]] || { echo "the $LABEL pool is not mounted at / or /var"; exit 0; }

problem=""
if btrfs filesystem show "$pool" | grep -i missing >/dev/null; then
    problem="is missing an SSD. Nothing is mirrored until it is rebuilt."
elif btrfs filesystem df "$pool" | grep -E '^(Data|Metadata|System), ' | grep -v ', RAID1:' >/dev/null; then
    problem="has data that is not RAID1 (written while one SSD was missing)."
fi

if [[ -z $problem ]]; then
    rm -f "$MOTD" "$ISSUE"
    echo "the $LABEL pool is whole and all RAID1"
    exit 0
fi
text="*** The $LABEL btrfs pool $problem
*** Put the new SSD in and run: sudo minipool-rebuild"
mkdir -p "${MOTD%/*}" "${ISSUE%/*}"
printf '\n%s\n\n' "$text" > "$MOTD"
printf '%s\n\n' "$text" > "$ISSUE"
while read -r line; do echo "<4>$line"; done <<<"$text"   # journal: warning
NOTICESCRIPT
chmod 0755 /etc/minipool/degraded-notice

cat > /etc/systemd/system/minipool-degraded-notice.service <<'UNIT'
[Unit]
Description=Warn at login while the minipool pool is degraded
After=local-fs.target
Before=systemd-user-sessions.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/bash /etc/minipool/degraded-notice

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable minipool-degraded-notice.service

mkdir -p /etc/tmpfiles.d
cat > /etc/tmpfiles.d/minipool.conf <<'TMPFILES'
L /usr/local/sbin/minipool-rebuild - - - - /etc/minipool/rebuild
TMPFILES
# ---- end of degraded boot entry ---------------------------------------------
