# ---- degraded boot entry (from kickstart/degraded-boot.sh) ------------------
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
# ---- end of degraded boot entry ---------------------------------------------
