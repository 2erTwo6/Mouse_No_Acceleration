# Mouse No Acceleration (`mouse_no_accel`)

A Magisk / KernelSU / APatch module that removes **mouse pointer acceleration** on Android 16
(arm64) by making the input reader use AOSP's own *flat* pointer curve - the same code path the
framework takes when mouse pointer acceleration is disabled.

* Tested device: Redmi `dash` (Redmi Turbo 5 Max), HyperOS `OS3.0.305.0.WPLCNXM`, Android 16 (`BP2A.250605.031.A3`)
* Tested loader: APatch (the layout is the standard Magisk module layout)
* The stock library is **never modified on disk**: a verified patched copy is bind-mounted over it
  on every boot and the mount disappears on reboot / module removal.

## Why a binary patch is needed

Android 16 computes mouse pointer movement in
`android::CursorInputMapper::configureOnChangePointerSpeed()` (`libinputreader.so`, inside
`system_server`):

```cpp
mPointerVelocityControl.setCurve(
        config.mousePointerAccelerationEnabled
                ? createAccelerationCurveForPointerSensitivity(config.mousePointerSpeed) // accelerated
                : createFlatAccelerationCurve(config.mousePointerSpeed));                // flat
```

With the accelerated curve and `pointer_speed=0`, the gain goes from **2.04x** at low speed to
**9.63x** at high speed (`MOUSE_CPI = 800`, segments at 32 / 52.8 / 119.1 mm/s). The flat curve is
a single segment with an infinite max speed: a constant gain of `1.0..3.5` (`2.25` at
`pointer_speed=0`), i.e. no velocity dependence, while the system *pointer speed* setting still
works.

Android 16 does have an official switch for this -
`Settings.System.mouse_pointer_acceleration_enabled` (`InputSettingsObserver` ->
`NativeInputManagerService.setMouseAccelerationEnabled()`, implemented and functional). On the
ROMs this module was written for that path is dead: it is gated by the aconfig flag
`com.android.hardware.input.pointer_acceleration`, which is fixed read-only at build time
(`device_config` has no registered default for it, and writing the setting has no effect).
MIUI/HyperOS's own escape hatch, `MiCursorInputMapperStub::needDisablePointerVelocityControl()`,
only matches the hard-coded Xiaomi VID/PID `2717:6577` (and laser pointers), so third-party mice
always get the accelerated curve.

## What is patched

`/system/lib64/libinputreader.so` (the 32-bit copy is irrelevant: `system_server` is 64-bit).

```
0xcacd8: cmp  w8, #1              ; 7100051f   config.mousePointerAccelerationEnabled
0xcacdc: b.ne 0xcacec             ; 54000081   <-- patched to 14000004 (b) => always flat
0xcace0: mov  x8, sp              ; 910003e8
0xcace4: bl   createAccelerationCurveForPointerSensitivity(int)
0xcace8: b    0xcacf4             ; 14000003
0xcacec: mov  x8, sp              ; 910003e8   flat branch
0xcacf0: bl   createFlatAccelerationCurve(int)
```

| Mode | Offset | Stock word | Patched word | Effect |
|------|--------|-----------|--------------|--------|
| `flat` (default) | `0xcacdc` | `54000081` (`b.ne +0x10`) | `14000004` (`b +0x10`) | always `createFlatAccelerationCurve()`: linear, pointer speed still adjustable |
| `raw` | `0xcb410` | `370000c0` (`tbnz w0,#0,+0x18`) | `14000006` (`b +0x18`) | skips `mPointerVelocityControl.move()` entirely: raw 1:1 counts (pointer speed has no effect on mice) |

Mode is selected in [`config.sh`](config.sh), then reboot.

Tested build of the library:
`sha256 = fdce4510a0da5fd74a1671e9e5a2d2e6d4f881bc8fa659baa5abdc7af4b75d1a`, patched copy:
`f679e8589050f6f0588cd120a541d15030cc8ba18344c3709a35897baf936ad1`.

## Install

Copy the files to `/data/adb/modules/mouse_no_accel` (the directory name should match the module
`id`) and reboot:

```sh
su -c 'mkdir -p /data/adb/modules/mouse_no_accel && \
       cp -f README.md module.prop config.sh post-fs-data.sh service.sh uninstall.sh \
             /data/adb/modules/mouse_no_accel/ && \
       chown -R 0:0 /data/adb/modules/mouse_no_accel && \
       chmod 755 /data/adb/modules/mouse_no_accel/*.sh && \
       reboot'
```

The module needs no installer logic; `post-fs-data.sh` does everything at boot. A soft reboot
(`setprop ctl.restart zygote`) does **not** re-run `post-fs-data`, it only helps if the bind mount
is already in place.

## Verify

`/data/adb/modules/mouse_no_accel/mouse_no_accel.log`:

```
patched fresh copy mode=flat offset=0xcacdc 54000081->14000004
result mode=flat mount=ok inode_same=yes visible_word=14000004 (want 14000004) mounts=1
boot check [LIVE (system_server maps the patched library)]: mode=flat word@0xcacdc=14000004 ...
```

`LIVE` means the `libinputreader.so` mapping inside `system_server` has the same inode as the
patched copy, i.e. the running input reader really is patched. `service.sh` reads this from
`/proc/<pid>/maps` field 5 - note that `stat()` on `/proc/<pid>/map_files/*` does *not* resolve to
the mapped file's inode on Android and must not be used for this check.

Manual check on the device: move the mouse very slowly over a fixed physical distance, then as fast
as possible over the same distance. With acceleration the fast pass travels much farther; with the
module the two match.

## Safety

* The stock `sha256` is checked first; on an unknown build the module falls back to a **unique
  instruction-pattern scan** (`od` + `awk` sliding window).
* The word at the patch offset is verified **before** patching and the patched copy is verified
  **after** patching.
* If the hash is unknown, the scan is ambiguous/empty, or the bytes do not match, the module logs
  and does **nothing** - it never guesses.
* Boot-loop guard: 4 runs within 10 minutes writes `disabled` and stops touching the library.
* The patched copy lives at `$MODDIR/libinputreader.patched.so`, deliberately **not** under
  `$MODDIR/system/`, so no loader can magic-mount a stale copy over a library from a newer ROM.
* The mount is performed in init's mount namespace (`nsenter -t 1 -m -- mount --bind`), after
  `chcon u:object_r:system_file:s0`, so `system_server` can map it.

## Portability

The *mechanism* is generic, this *implementation* is verified on one build:

| Aspect | Status |
|---|---|
| Architecture | arm64 only (`system_server` is 64-bit) |
| Android version | Android 16 only. Android 15 and older have a structurally different input reader (the `enable_new_mouse_pointer_ballistics` aconfig flag, `mOldPointerVelocityControl`, `displaysWithMousePointerAccelerationDisabled`), so the patch site differs |
| Library | scans `/system/lib64/libinputreader.so`. On older branches `CursorInputMapper` lives in `libinputflinger.so` and would have to be added |
| ROM updates | The `sha256` changes, so the pattern scan takes over. It works when the code shape is unchanged (usually the case for minor updates on the same AOSP revision); otherwise the module stays idle |
| Vendor changes | `flat` patches pure AOSP code (more portable). `raw` patches code that MIUI modified, so on non-Xiaomi ROMs that pattern may not exist |
| When idle | Nothing is modified; the log says `SKIP`/`NOT-APPLIED` |

For broad multi-device coverage, symbol/Java level approaches are better suited than byte patches:

* **Zygisk PLT hook** - `libinputreader.so` imports `createAccelerationCurveForPointerSensitivity`
  from `libinput.so` through the PLT, so hooking that symbol to return the flat curve is
  version-robust (symbol names are stable across builds).
* **LSPosed** - hook `android.hardware.input.InputSettings.isMousePointerAccelerationEnabled()` to
  return `false` in the system framework scope: that drives the official JNI path
  (`setMouseAccelerationEnabled(false)` -> flat curve) without touching any binary. Android 16 only,
  and it hooks `system_server`, which is a higher-risk process.

## Revert

Delete `/data/adb/modules/mouse_no_accel` and reboot (or run `uninstall.sh`). Nothing on the system
partition was ever changed.

## Disclaimer

This module changes the behaviour of a system library at runtime. It was verified on the device
listed above, but you use it at your own risk - keep a way to remove the module (e.g. a root shell)
before installing it on a device you depend on.

## License

MIT, see [LICENSE](LICENSE) (c) 2026 2erTwo6.
