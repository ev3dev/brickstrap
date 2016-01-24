generic debian jessie brickstrap project
----------------------------------------

The goal of this project is to be able to create bootable images for as
many embedded systems as possible using Debian Jessie. The images are minimal
and intended to be used as an example/template for other projects. Send a
pull request if you get a board that isn't listed working.

So far, this can create a very minimal bootable image with a serial console
(no networking yet). Default user:pass is `debian:changeme`.

To create an image, run...

    brickstrap -p generic-jessie -c base -c armmp -c beaglebone-black -d bbb all

## Components

Base components:

* `base` - shared by everything
* `armmp` - common packages for debian armmp kernel

Board components:

* `beaglebone-black`
