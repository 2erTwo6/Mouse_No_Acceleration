#!/system/bin/sh
# mouse_no_accel -- post-fs-data stage (runs before zygote/system_server starts)
#
# Patches one AArch64 instruction in /system/lib64/libinputreader.so so that
# android::CursorInputMapper::configureOnChangePointerSpeed() always selects the flat
# acceleration curve, then bind-mounts the patched copy over the original.
#
# Tested build: Redmi "dash" / HyperOS OS3.0.305.0.WPLCNM / Android 16 (BP2A)
#   stock libinputreader.so sha256 = fdce4510a0da5fd74a1671e9e5a2d2e6d4f881bc8fa659baa5abdc7af4b75d1a
#   flat: file offset 0xcacdc  54000081 (b.ne +0x10)         -> 14000004 (b +0x10)
#   raw : file offset 0xcb410  370000c0 (tbnz w0,#0,+0x18)   -> 14000006 (b +0x18)
#
# Design notes:
#  * The patched copy is kept OUTSIDE $MODDIR/system on purpose. If it lived there, a loader
#    that applies the module overlay before this script runs would shadow the stock library,
#    and after a ROM update a stale copy could be mounted over the new one. Here the stock
#    library is always read from the real (unshadowed) path and verified byte by byte.
#  * On any mismatch (ROM update, unexpected bytes, ambiguous scan) the module does nothing.
#  * The stock file on disk is never modified: only a bind mount is added.

umask 022

MODDIR=${0%/*}
SRC=/system/lib64/libinputreader.so
DST=$MODDIR/libinputreader.patched.so
SUMF=$MODDIR/stock.sha256
LOG=$MODDIR/mouse_no_accel.log
KNOWN_HASH=fdce4510a0da5fd74a1671e9e5a2d2e6d4f881bc8fa659baa5abdc7af4b75d1a

[ -f "$MODDIR/config.sh" ] && . "$MODDIR/config.sh"
MODE=${MODE:-flat}

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

case "$MODE" in
  raw) OFF=$((0xcb410)); EXPECT=370000c0; PATCHED=14000006; PATBYTES='\x06\x00\x00\x14'
       PATTERN="370000c0 91016260 910553e2 910543e3"; PIDX=0 ;;
  *)   OFF=$((0xcacdc)); EXPECT=54000081; PATCHED=14000004; PATBYTES='\x04\x00\x00\x14'
       PATTERN="7100051f 54000081 910003e8"; PIDX=1 ;;
esac

if [ -f "$MODDIR/disabled" ]; then
  log "disabled marker present, skipping"
  exit 0
fi

# ---- boot-loop guard: 4 runs within 10 minutes disables the module --------------------
now=$(date +%s)
last=0; cnt=0
if [ -f "$MODDIR/boots" ]; then
  last=$(cut -d' ' -f1 "$MODDIR/boots" 2>/dev/null)
  cnt=$(cut -d' ' -f2 "$MODDIR/boots" 2>/dev/null)
fi
case "$last" in ''|*[!0-9]*) last=0 ;; esac
case "$cnt"  in ''|*[!0-9]*) cnt=0  ;; esac
if [ "$last" -gt 0 ] && [ $((now - last)) -lt 600 ]; then
  cnt=$((cnt + 1))
else
  cnt=1
fi
echo "$now $cnt" >"$MODDIR/boots"
if [ "$cnt" -ge 4 ]; then
  echo "disabled after $cnt quick reboots" >"$MODDIR/disabled"
  log "DISABLED after $cnt quick reboots"
  exit 0
fi

[ -f "$SRC" ] || { log "SKIP: $SRC not found"; exit 0; }

# ---- locate the patch site -----------------------------------------------------------
hash=$(sha256sum "$SRC" 2>/dev/null | cut -d' ' -f1)
if [ "$hash" != "$KNOWN_HASH" ]; then
  log "unknown build sha256=$hash, trying pattern scan (mode=$MODE)"
  WORDS=$MODDIR/scan.words
  od -An -tx4 -v -w4 "$SRC" 2>/dev/null | tr -s " " "\n" | grep -v "^$" >"$WORDS"
  set -- $(awk -v pat="$PATTERN" -v k="$PIDX" '
    BEGIN { n = split(pat, p, " ") }
    { line[NR % n] = $0
      if (NR >= n) {
        m = 1
        for (i = 0; i < n; i++) if (line[(NR - i) % n] != p[n - i]) { m = 0; break }
        if (m) { hits++; if (hits == 1) first = NR - n }
      }
    }
    END { printf "%d %d\n", hits + 0, 4 * (first + k) }
  ' "$WORDS" 2>/dev/null)
  rm -f "$WORDS"
  if [ "$1" = "1" ] && [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null; then
    OFF=$2
    log "scan found unique patch site at 0x$(printf %x "$OFF")"
  else
    log "scan failed (hits=${1:-?}); SKIP (module idle)"
    exit 0
  fi
fi

cur=$(od -An -tx4 -j "$OFF" -N 4 "$SRC" 2>/dev/null | tr -d ' ')
if [ "$cur" != "$EXPECT" ]; then
  log "SKIP: word at 0x$(printf %x "$OFF") is '$cur', expected $EXPECT (already patched or other build?)"
  exit 0
fi

# ---- build (or reuse) the patched copy -----------------------------------------------
reuse=0
if [ -f "$DST" ] && [ -f "$SUMF" ] && [ "$(cat "$SUMF" 2>/dev/null)" = "$hash" ]; then
  if [ "$(od -An -tx4 -j "$OFF" -N 4 "$DST" 2>/dev/null | tr -d ' ')" = "$PATCHED" ]; then
    reuse=1
  fi
fi

if [ "$reuse" = "0" ]; then
  cp -f "$SRC" "$DST" || { log "SKIP: copy failed"; exit 0; }
  printf "$PATBYTES" | dd of="$DST" bs=1 seek="$OFF" conv=notrunc 2>/dev/null
  got=$(od -An -tx4 -j "$OFF" -N 4 "$DST" 2>/dev/null | tr -d ' ')
  if [ "$got" != "$PATCHED" ]; then
    log "SKIP: patch verify failed (word=$got)"
    rm -f "$DST" "$SUMF"
    exit 0
  fi
  echo "$hash" >"$SUMF"
  log "patched fresh copy mode=$MODE offset=0x$(printf %x "$OFF") $EXPECT->$PATCHED"
else
  log "reusing existing patched copy (stock sha unchanged)"
fi

chown 0:0 "$DST" 2>/dev/null
chmod 0644 "$DST" 2>/dev/null
chcon u:object_r:system_file:s0 "$DST" 2>/dev/null

# ---- mount it over the real library --------------------------------------------------
# Mount inside init's mount namespace first: that is the namespace zygote/system_server is
# forked from. Then also in our own namespace as a fallback (identical content).
mounted=no
if /system/bin/nsenter -t 1 -m -- mount --bind "$DST" "$SRC" 2>>"$LOG"; then
  mounted=ok
elif mount --bind "$DST" "$SRC" 2>>"$LOG"; then
  mounted=fallback
fi

vi=$(stat -c %i "$SRC" 2>/dev/null)
di=$(stat -c %i "$DST" 2>/dev/null)
w=$(od -An -tx4 -j "$OFF" -N 4 "$SRC" 2>/dev/null | tr -d ' ')
same=no
[ -n "$vi" ] && [ "$vi" = "$di" ] && same=yes
log "result mode=$MODE mount=$mounted inode_same=$same visible_word=$w (want $PATCHED) mounts=$(grep -c libinputreader /proc/mounts 2>/dev/null)"
exit 0
