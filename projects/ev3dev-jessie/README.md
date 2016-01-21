ev3dev.org debian jessie brickstrap project
-------------------------------------------

This project can create image files for LEGO MINDSTORMS EV3, Raspberry Pi
and Raspberry Pi 2.

The configurations used to create official ev3dev.org images are:

    # for LEGO MINDSTORMS EV3
    brickstrap -p ev3dev-jessie -c base -c debian -c ev3 all
    # for Raspberry Pi (1) Model A/A+/B/B+
    brickstrap -p ev3dev-jessie -c base -c raspbian -c rpi-base -c rpi1 all
    # for Raspberry Pi 2
    brickstrap -p ev3dev-jessie -c base -c debian -c rpi-base -c rpi2 all

### Description of Components

* Core components (required)

    * `base` contains the common files used on all platforms. This should always
       be included.
    * `debian` and `raspbian` dictate which package repositories to use. Include
      one and only one of these.

* Platform components (chose one)

    * `ev3` contains items that only apply to LEGO MINDSTORMS EV3 hardware.
    * `rpi1` contains items for Raspberry Pi (1) hardware.
    * `rpi2` contains items for Raspberry Pi 2 hardware.
    * `rpi-base` contains items common to all Raspberry Pi images. Must include
      this as well if you are choosing one of the `rpi1/2` components.

### Notes

There are some suspicious looking warnings that are perfectly normal.


     Hmm. There is a symbolic link /lib/modules/<kernel-version>/build
     However, I can not read it: No such file or directory
     Therefore, I am deleting /lib/modules/<kernel-version>/build


     Hmm. The package shipped with a symbolic link /lib/modules/<kernel-version>/source
     However, I can not read the target: No such file or directory
     Therefore, I am deleting /lib/modules/<kernel-version>/source

This comes from the kernel package because I have never taken the time to fix it.

    Warning: root device /dev/mmcblk0p2 does not exist

True, it doesn't exist in the brickstrap environment, but it will exist on the
actual device. So no worries.

    update-rc.d: warning: start and stop actions are no longer supported; falling back to defaults

Still does what we want it to even if it isn't "supported".

    sysvinit: All runlevel operations denied by policy
    invoke-rc.d: policy-rc.d denied execution of start.

This is good. We don't want services/daemons starting in the brickstrap environment.

    Failed to set capabilities on file `/bin/ping' (Invalid argument)

This is because we are using kernel namespaces instead of real `root`. We don't
have permission to set capabilities because we aren't `root`. The `ping` package
falls back to using `suid`, so ping still works.

    Failed to set capabilities on file `/usr/bin/systemd-detect-virt' (Invalid argument)
    The value of the capability argument is not permitted for a file. Or the file is not a regular (non-symlink) file

Same thing with file capabilities.
