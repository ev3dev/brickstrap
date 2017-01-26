% BRICKSTRAP(1) | User's Manual
% David Lechner
% August 2016

# NAME

brickstrap - Create bootable disk images from Docker images


# SYNOPSIS

brickstrap create-tar \<*docker-image*> \<*tar-file*>

brickstrap create-image \<*tar-file*> \<*image-file*>

brickstrap add-beagle-bootloader \<*docker-image*> \<*image-file*>

brickstrap create-report \<*docker-image*> \<*report-directory*>


# DESCRIPTION

Brickstrap is a tool to create bootable disk images for embedded systems using
Docker images. The creation of Docker images is outside of the scope of this
manual. See <https://docs.docker.com/engine/> for more info.

Note: Although "brick" is generally a bad word in the embedded world, the
"brick" in `brickstrap` comes from the fact that this tool was originally
developed to create image files for the LEGO MINDSTORMS EV3 programmable brick.


# COMMANDS

`create-tar`
: Creates a tar file from the docker image. This is not the same as `docker export`.
See *DOCKER IMAGE* below for details.

`create-image`
: Create a disk image from the tar file. Also see *ENVIRONMENT* for variables
that will affect the creation of the image.

`add-beagle-bootloader`
: Writes Beagle board bootloader files to the existing disk image. See *BEAGLE
BOOTLOADER* below for details.

`create-report`
: Creates a report from the docker image. See the *DOCKER IMAGE* section below
for details.


# OPTIONS

*docker-image*
: The name of a Docker image to be used as the source for creating a tar file.
The `docker` command is used, so if the image does not already exist on the
system, `docker` will attempt to download it.  See *DOCKER IMAGE* below.

*tar-file*
: The name of the tar file. The `create-tar` command will create this file.
The `create-image` file uses this as the source.

*image-file*
: The name of the raw disk image file. The `create-image` command will create
this file. The `add-beagle-bootloader` command will modify this file.

*report-directory*
: The directory where reports will be generated. This directory will be created
if it does not already exist.

# DOCKER IMAGE

There are some special considerations that need to be taken into account when
creating the docker images. See <https://github.com/ev3dev/docker-library> for
a real-life example of how Docker images are created for use with `brickstrap`.

* __The `/brickstrap/` directory__

    Docker images should contain a `/brickstrap/` directory. This directory
    contains extra info that can be used during the creation of the Docker
    image. It is not included in the disk image that is created.

* __Excluding files from the disk image__

    It is useful to exclude some files from the disk image. For example, most
    Docker images contain `/usr/sbin/policy-rc.d` to prevent init scripts from
    running. If this is included in the disk image, the system probably won't boot.

    If the Docker image has `tar` >= 1.28, files can be excluded by creating a
    `.brickstrap-tar-exclude` file in each directory that contains files to be
    excluded. This will be used by the `--exclude-ignore` option of the `tar`
    command. The `.brickstrap-tar-exclude` file contains a list of files to be
    ignored in the current directory.

    If the Docker image has `tar` < 1.28, the file `/brickstrap/_tar-exclude`
    will be passed to the `--exclude-from` option of the `tar` command. This
    file contains a list of files to be ignored. Absolute paths must start with
    `./` in order to correctly match the file name.

* __Adding extra files to the disk image__

    Sometimes, having a file in the Docker image can cause the Docker image to
    not work properly when using it in a Docker container. These files should
    be omitted from their proper place in the Docker image. Instead, these files
    should be placed in `/brickstrap/_tar-only/`. This contents folder will be
    appended to the tar file when it is created. So, for example, the file
    `/brickstrap/_tar-only/etc/my.conf` will end up as `/etc/my.conf` in the
    disk image.

* __The `/boot/flash/` directory__

    This directory becomes the boot partition (FAT) of the disk image. Place
    any boot files here.

* __The `/brickstrap/_report/` directory__

    Any executable files in this directory or its subdirectories will be run as
    part of the `brickstrap create-report` command. The files should save any
    reports to `/brickstrap/_report/_out/` (the `_out/` directory will be
    created automatically). The `BRICKSTRAP_DOCKER_IMAGE_NAME` environment
    variable will be set to *docker-image* when these commands are executed.


# BEAGLE BOOTLOADER

Beagle boards have a unique way of handling the bootloader files by placing
them at specific locations in the disk image rather than using regular files.
See <http://elinux.org/Beagleboard:U-boot_partitioning_layout_2.0> for more
information.

The `add-beagle-bootloader` command expects to find files named `MLO` and
`u-boot.img` in the `/brickstrap/_beagle-boot/` directory in the Docker image.

The actual bootloader files are available from <https://rcn-ee.com/repos/bootloader>.
You can find the latest stable BeagleBone bootloader by running:

    wget https://rcn-ee.com/repos/bootloader/latest/bootloader-ng \
        -q -O - | grep "ABI2:am335x_evm:"


# ENVIRONMENT

The following environment variables are used by the `create-image` command.

`BRICKSTRAP_IMAGE_FILE_SIZE`
: This specifies the size of the disk image that is created. The default is
`3800M` (chosen to fit on any 4GB media - sometimes you don't get the full 4GB).
The FAT partition size is currently fixed at 48MB. See the `guestfish` man page
for allowable size suffixes and their definitions.

`BRICKSTRAP_BOOT_PART_LABEL`
: This specifies the boot partition label. The default is `BOOT`. Cannot exceed
11 characters. The characters `? / \ | . , ; : + = [ ] < > "` are not allowed.
Lower case will be converted to upper case.

`BRICKSTRAP_ROOT_PART_LABEL`
: This specifies the root file system partition label. The default is `ROOTFS`.
Cannot exceed 16 characters.
