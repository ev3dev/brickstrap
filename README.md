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

There is also a Debian package available for Ubuntu trusty in the ev3dev package
repository.

    sudo apt-key adv --keyserver pgp.mit.edu --recv-keys 2B210565
    sudo apt-add-repository "deb http://archive.ev3dev.org/ubuntu trusty main"
    sudo apt-get update
    sudo apt-get install brickstrap


If you just want to run from git, make sure you have these packages installed.
They will be installed automatically if you use the `brickstrap` package, so you
can skip this if that is the case. You only need `qemu-user-static` if the
Docker image is for a foreign architecture.

    sudo apt-get install docker-engine libguestfs-tools qemu-user-static

If you have never used `libguestfs` before, you need to set it up. **Note:**
`update-guestfs-appliance` may not exist in newer versions of guestfs. If get
an error for that command, ignore it and move on.

    # create a supermin appliance
    sudo update-guestfs-appliance
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
