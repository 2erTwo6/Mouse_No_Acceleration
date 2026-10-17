#!/system/bin/sh
# mouse_no_accel -- late_start service stage: report whether the patched library is really live.
#
# The decisive check is the inode of the libinputreader.so mappings inside system_server, read
# from /proc/<pid>/maps (field 5). Note: stat() on /proc/<pid>/map_files/* does NOT resolve to
# the mapped file's inode on Android, so it must not be used for this check.

umask 022
MODDIR=${0%/*}
LOG=$MODDIR/mouse_no_accel.log
SRC=/system/lib64/libinputreader.so
DST=$MODDIR/libinputreader.patched.so

[ -f "$MODDIR/config.sh" ] && . "$MODDIR/config.sh"
case "${MODE:-flat}" in
  raw) OFF=$((0xcb410)); WANT=14000006 ;;
  *)   OFF=$((0xcacdc)); WANT=14000004 ;;
esac

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 60 ]; do
  sleep 2; i=$((i+1))
done
sleep 5

w=$(od -An -tx4 -j "$OFF" -N 4 "$SRC" 2>/dev/null | tr -d ' ')
vis_ino=$(stat -c %i "$SRC" 2>/dev/null)
dst_ino=$(stat -c %i "$DST" 2>/dev/null)
sp=$(pidof system_server)

srv_ino=""
if [ -n "$sp" ]; then
  srv_ino=$(awk '/libinputreader\.so/ {print $5}' /proc/$sp/maps 2>/dev/null | sort -u | tr '\n' ',')
fi

verdict="NOT-APPLIED"
if [ "$w" = "$WANT" ] && [ -n "$dst_ino" ] && [ "$vis_ino" = "$dst_ino" ]; then
  verdict="mounted-but-not-used-by-system_server"
  case ",$srv_ino" in
    *",$dst_ino,"*) verdict="LIVE (system_server maps the patched library)" ;;
  esac
fi

log "boot check [$verdict]: mode=${MODE:-flat} word@0x$(printf %x "$OFF")=$w want=$WANT patched_ino=$dst_ino visible_ino=$vis_ino server_map_ino=[$srv_ino] mounts=$(grep -c libinputreader /proc/mounts 2>/dev/null)"
