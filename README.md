brickstrap
==========

brickstrap is a tool for creating bootable image files for embedded systems
using Debian Linux.


About
-----

brickstrap is a fork of [polystrap] which was born from [this idea][blog].
Basically, it automates a stack of other tools to provide and end-to-end
solution of turning some configuration files into a bootable image all without
the need for root privileges. The stack of tools consists of:

* [user-unshare]: Handles kernel namespaces and bind mounting host paths.
* [multistrap]: Bootstraps a Debian system using multiple APT sources.
* [libguestfs]: Creates the actual disk image.

The name "brickstrap" comes from the fact that it was developed to bootstrap
the [LEGO MINDSTORMS EV3 Intelligent Brick][mindstorms] as part of the [ev3dev]
project. Nevertheless, it works well for other embedded systems too. We have
Rapsberry Pi and soon will have BeagleBone Black configurations as well.


Installation
------------

Since brickstrap is essentially just a bash script, you can run directly from
the source code.

    git clone git://github.com/ev3dev/brickstrap
    brickstrap/brickstrap.sh all

There is also a Debian package available for Ubuntu trusty in the ev3dev package
repository.

    sudo apt-key adv --keyserver pgp.mit.edu --recv-keys 2B210565
    sudo apt-add-repository "deb http://ev3dev.org/debian trusty main"
    sudo apt-get update
    sudo apt-get install brickstrap

If you just want to run from git, make sure you have these packages installed.
They will be installed automatically if you use the `brickstrap` package, so you
can skip this if that is the case.

    sudo apt-get install qemu-user-static (>= 1.0), multistrap, libguestfs-tools, uidmap

If you have never used `libguesfs` before, you need to set it up. **Note:**
`update-guestfs-appliance` may not exist in newer versions of guestfs. If get
an error for that command, ignore it and move on.

    # create a supermin appliance
    sudo update-guestfs-appliance
    # add yourself to the kvm group
    sudo usermod -a -G kvm $USER
    newgrp kvm
    # fix permissions on /boot/vmlinuz*
    sudo chmod +r /boot/vmlinuz*

And you need to add yourself to `/etc/subuid` and `/etc/subgid` to be able to
use uid/gid mapping.

    sudo usermod --add-subuids 200000-265534 --add-subgids 200000-265534 $USER

Usage
-----

Assuming you have an existing board definition (more on board definitions later),
you just have to run...

    brickstrap all -b <board>

__Note:__ If `brickstrap` is not in your path, then you need to specify the full
path to `brickstrap.sh` wherever you saved it.

This will create a `<name>` folder, a `<name>.tar` and a `<name>.img` file in
the current directory. `<name>` is determined by the board configuration file.

Additionally, brickstrap provides a `shell` command that lets
you chroot into the root file system that was created. This lets you make
changes manually which can then be used to create a new image file like this...

    brickstrap shell -b <board> -d <name>
    # make some changes
    exit
    brickstrap create-tar -b <board> -d <name>
    brickstrap create-image -b <board> -d <name>

We have also found `brickstrap shell` to be useful as a cross-compiler since
you can download and install Debian packages and it uses QEMU to run foreign
binaries (like gcc).


Board Configuration Directories
-------------------------------

Each directory in this repository represents a board configuration. Any board
that is not actively maintained should be moved to the `_unmaintained` directory.
You can create a new board configuration by copying one if the existing ones.

__Note:__ brickstrap will look for a board configuration directory in the current
working directory and then in the directory where `brickstrap.sh` is located.
So, if you installed the Debian package and you want to override one of the
existing board configurations, just copy it to your current working directory.

### The `config` file

This is the main configuration file. It specifies a number of environment
variables that are used. It might look something like this...

    SUITE="jessie"
    ARCH="armel"
    MIRROR="http://ftp.debian.org/debian"
    IMAGE_FILE_SIZE="900M"

Most of the variables are just used to generate the `multistrap.conf` file, so
they are only need if they are used in that file. The variables used by the actual
brickstrap script are:

*   `IMAGE_FILE_SIZE`: Passed to `guestfish` to determine the final image size.

It may also be useful to use the pattern:

    MIRROR=${MIRROR:-http://ftp.debian.org/debian}

so that environment variables can be passed to brickstrap to override the
default values.

### The `multistrap.conf` file

You can read more about this in the multistrap man page. Any environment variables
in the file will be substituted using the current environment and the `config` file.

### The `debconfseed.txt` file

This file contains a list of package options to set for packages. Lines look
like this:

    <package> <package>/<option> select <value>

where `<package>` is the name of a package, `<option>` is the name of the option
and `<value>` is the value to set the option to. You can see if a package has
options by running `debconf-show <package>`.

Since we are not actually using debconf, other debconf options won't have any effect.

### The `preinst.blacklist` file

This file contains a list of package names that should be skipped when running
the `preinst` scripts.

By default, brickstrap tries to run the `preinst` script from every package that
is installed. However, since we are using multistrap, the packages are unpacked
before running this script, which can cause problems. `preinst` scripts normally
expect that they are run before the other files in the package are unpacked.
For example, `sudo` breaks if we run its `preinst` script, so it needs to be
listed in `preinst.blacklist`.

### The `root` directory

Files in this directory will be copied to the root file system created by
brickstrap. This is used for files that are not provided by any package, such
as `/etc/fstab`. Symbolic links will be dereferenced (so if you actually need
a symbolic link, you have to create it with a hook instead). The files are
copied after package are unpacked, but before packages are configured.

### The `root/boot/flash` directory

The contents of this directory will be moved to the FAT partition of the image
file when it is created. So, for example, if you have a `uImage` file of the
kernel that is needed in the FAT partition by the bootloader, then just place it
at `root/boot/flash/uImage` and brickstrap will take care of the rest.

### The `packages` directory

This directory contains files withs lists of package names. You can use multiple
files to organize packages or you can have one great big file. The package names
will be included in the generated multistrap.conf file.

**The files must end with a blank line or else the last package name will be
skipped!**

### The `hooks` directory

This directory contains shell scripts that are run after packages have been
configured. They can be used to do any fixing up or cleaning up needed.

Scripts are called using `.`, so shebangs will be ignored.

### The `tar-exclude` file

This file contains a list of files that you *do* want in the brickstrap shell
but *don't* want in the final image file. For example, `/usr/sbin/policy-rc.d`
is used to prevent `/etc/init.d` scripts from running during the bootstrapping
process, but it would be very problematic when trying to run on the device.

### The `tar-only` directory

This directory contains files that we *don't* want in brickstrap shell but *do*
want in the final image file. For example, at one time, in ev3dev-jessie, we had
`/etc/flash-kernel/db` that specifies the install location of the kernel at
`/dev/mmcblk0p1`. This broke `flash-kernel` in the bootstrap environment, but
was required in the actual image file.

The files in this directory must include the full path as if they were in the
root directory.

This directory is copied to `/tar-only` in the `$ROOTDIR`. Hooks can also create
additional files there. During the `create-tar` stage, brickstap will append
the files in `$ROOTDIR/tar-only` to the tarball. This means that files in this
directory will overwrite any files in `$ROOTDIR` with the same name.



[polystrap]: https://gitlab.mister-muffin.de/josch/polystrap
[blog]: https://blog.mister-muffin.de/2014/01/11/why-do-i-need-superuser-privileges-when-i-just-want-to-write-to-a-regular-file/
[QEMU]: http://wiki.qemu.org/Main_Page
[user-unshare]: https://blog.mister-muffin.de/2015/10/25/unshare-without-superuser-privileges/
[multistrap]: https://wiki.debian.org/Multistrap
[libguestfs]: http://libguestfs.org
[mindstorms]: http://mindstorms.lego.com
[ev3dev]: http://www.ev3dev.org
