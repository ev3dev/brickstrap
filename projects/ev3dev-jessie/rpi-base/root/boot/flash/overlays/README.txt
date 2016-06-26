This directory is where the bootloader looks for device tree overlays.
You can copy overlays from /usr/lib/linux-image-<kernel-version>/overlays/*.dtbo
or create your own. You must also enable the overlays in config.txt.

Run `zless /usr/share/doc/raspberrypi-bootloader/README.overlays.gz` or visit
<http://www.raspberrypi.org/documentation/configuration/device-tree.md> for
more information.
