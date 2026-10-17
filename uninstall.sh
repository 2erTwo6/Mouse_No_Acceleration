#!/system/bin/sh
# mouse_no_accel -- cleanup on uninstall (the bind mount also disappears on reboot).

umask 022
MODDIR=${0%/*}
umount /system/lib64/libinputreader.so 2>/dev/null
rm -f "$MODDIR/libinputreader.patched.so" "$MODDIR/stock.sha256" \
      "$MODDIR/scan.words" "$MODDIR/boots" "$MODDIR/disabled"
rm -rf "$MODDIR/system"
