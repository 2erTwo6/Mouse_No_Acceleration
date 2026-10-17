# mouse_no_accel configuration
#
# flat  (default): CursorInputMapper::configureOnChangePointerSpeed() is forced to always use
#                  createFlatAccelerationCurve(mousePointerSpeed). The gain becomes constant
#                  (1.0..3.5 depending on pointer speed, 2.25 at the default speed 0), i.e. a
#                  fast flick of the mouse moves the cursor the same distance as a slow move
#                  over the same physical distance. The system "pointer speed" setting still
#                  works, so you can tune sensitivity.
#
# raw            : CursorInputMapper::sync() is forced to skip mPointerVelocityControl.move()
#                  entirely -> raw 1:1 counts (same thing MIUI does for its own 2717:6577 mice).
#                  "pointer speed" has no effect on mice in this mode, and high-DPI mice may
#                  feel very slow or very fast.
#
MODE=flat
