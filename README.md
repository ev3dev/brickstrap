brickstrap
==========

Brickstrap is a tool for turning [Docker] images into bootable image files for
embedded systems.


About
-----

The name "brickstrap" comes from the fact that it was developed to bootstrap
the [LEGO MINDSTORMS EV3 Intelligent Brick][mindstorms] as part of the [ev3dev]
project. Nevertheless, it works well for other embedded systems too. We have
Raspberry Pi and BeagleBone configurations as well.


Installation
------------

Since `brickstrap` is essentially just a bash script, you can run directly from
the source code.

    git clone git://github.com/ev3dev/brickstrap
    brickstrap/src/brickstrap.sh create-tar my-docker-image my.tar
    
(Watch out for [this bug](https://bugs.launchpad.net/ubuntu/+source/libguestfs/+bug/1777058)
in Ubuntu 18.04. A workaround for this bug is included in the debian package mentioned below,
so you only need to manually fix the bug when running brickstrap from source.)

There is also a Debian package available for Ubuntu in the ev3dev tools package
repository.

    sudo add-apt-repository ppa:ev3dev/tools
    sudo apt update
    sudo apt install brickstrap

If you just want to run from git, make sure you have these packages installed.
They will be installed automatically if you use the `brickstrap` package, so you
can skip this if that is the case. You only need `qemu-user-static` if the
Docker image is for a foreign architecture.

    sudo apt-get install docker-ce libguestfs-tools qemu-user-static

If you have never used `libguestfs` before, you need do some manual steps:

    # add yourself to the kvm group
    sudo usermod -a -G kvm $USER
    newgrp kvm # or log out and log back in
    # fix permissions on /boot/vmlinuz*
    sudo chmod +r /boot/vmlinuz*


Usage
-----

See the [man page] or if you installed the Debian package, run `man brickstrap`.

[Docker]: https://www.docker.com
[ev3dev]: http://www.ev3dev.org
[libguestfs]: http://libguestfs.org
[mindstorms]: http://mindstorms.lego.com
[man page]: https://github.com/ev3dev/brickstrap/blob/master/docs/brickstrap.md
