# OverlayFS userdata growth with a cold RTC

The board's invalid cold-boot clock can put ext4's recorded last-mount time
after the initramfs filesystem check. Offline `resize2fs` then refuses a clean
filesystem and the boot stops before GNOME. Keep the unmounted `e2fsck` check,
mount userdata read-write, and grow it through ext4's online resize before
creating OverlayFS upper/work directories. Do not bypass checks or adjust
the clock to hide this failure.

`tests/host/test-overlay-online-resize.sh` runs in a private mount namespace,
reproduces the future timestamp and offline rejection, grows a 64 MiB ext4
image to 96 MiB while mounted, verifies a persisted sentinel and the final
filesystem integrity. It passed on native ARM64 209 on 2026-10-13; log:
`output/ubuntu-desktop-jr-20261011/qa/overlay-online-resize-host-20261013.log`.

The previous JR3576 lab image also recovered through cold boot and a
controlled panic with this initramfs fix. The fresh GNOME candidate needs its
own reboot and persistence gates; this host result does not promote it.
