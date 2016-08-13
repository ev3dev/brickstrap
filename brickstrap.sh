#!/bin/bash
#
# brickstrap - disk image creation tool
#
# MIT License
#
# Copyright (c) 2016 David Lechner <david@lechnology.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -e

function brickstrap_show_usage()
{
    echo "Usage:"
    echo
    echo "    brickstrap create-tar <docker-image> <tar-file>"
    echo "    brickstrap create-image <tar-file> <image-file>"
    echo "    brickstrap add-beagle-bootloader <docker-image> <image-file>"
}

function brickstrap_create_tar()
{
    # check that the required parameters are given
    if [ ! -n "$BRICKSTRAP_DOCKER_IMAGE_NAME" ]; then
        echo "Error: docker image not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_TAR_FILE" ]; then
        echo "Error: tar file name not specified"
        brickstrap_show_usage
        exit 1
    fi

    # --exclude-ignore requires tar >= 1.28, so first we check the tar version in
    # the docker image.

    echo "Checking docker image tar version..."

    BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION=$(docker run --rm $BRICKSTRAP_DOCKER_IMAGE_NAME \
        dpkg-query --show --showformat '${Version}' tar)

    echo "tar $BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION"

    if dpkg --compare-versions $BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION ge 1.28; then
        BRICKSTRAP_TAR_EXCLUDE_OPTION="--exclude-ignore .brickstrap-tar-exclude"
    else
        BRICKSTRAP_TAR_EXCLUDE_OPTION="--exclude-from /brickstrap/_tar-exclude"
    fi


    # Then create the actual image

    echo "Creating $BRICKSTRAP_TAR_FILE from $BRICKSTRAP_DOCKER_IMAGE_NAME..."

    docker run --rm -v $(pwd):/brickstrap/_tar-out $BRICKSTRAP_DOCKER_IMAGE_NAME \
        tar --create \
            --one-file-system \
            --preserve-permissions \
            --exclude "./brickstrap" \
            --exclude ".dockerenv" \
            $BRICKSTRAP_TAR_EXCLUDE_OPTION \
            --file "/brickstrap/_tar-out/$BRICKSTRAP_TAR_FILE" \
            --directory "/" \
            .
    echo "done"


    # There can be extra files that need to get added to the archive

    if docker run --rm $BRICKSTRAP_DOCKER_IMAGE_NAME test -d "/brickstrap/_tar-only"; then
        echo 'Appending /brickstrap/_tar-only/*'
        docker run --rm -v $(pwd):/brickstrap/_tar-out $BRICKSTRAP_DOCKER_IMAGE_NAME \
            tar --append \
                --preserve-permissions \
                --file "/brickstrap/_tar-out/$BRICKSTRAP_TAR_FILE" \
                --directory "/brickstrap/_tar-only" \
                .
        echo "done"
    fi
}

#
# Convert megabytes to sectors. Assumes 512B sectors.
#
# Params:
# $1: The size in megabytes
#
# Returns: the size in sectors
#
function brickstrap_mb_to_sectors()
{
    echo $(( $1 * 1024 * 1024 / 512 ))
}

function brickstrap_create_image()
{
    for SYSTEM_KERNEL_IMAGE in /boot/vmlinuz-*; do
        if [ ! -r "${SYSTEM_KERNEL_IMAGE}" ]; then
            echo "Cannot read ${SYSTEM_KERNEL_IMAGE} needed by guestfish"
            echo "Set permission with 'sudo chmod +r /boot/vmlinuz-*'"
            exit 1
        fi
    done

    # TODO: Test if virtualization is in use (such as VirtualBox is running)
    # and show error message explaining the situation.

    if [ ! -n "$BRICKSTRAP_TAR_FILE" ]; then
        echo "Error: tar file name not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -e "$BRICKSTRAP_TAR_FILE" ]; then
        echo "Error: tar file does not exist"
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_IMAGE_FILE_NAME" ]; then
        echo "Error: image file name not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_IMAGE_FILE_SIZE" ]; then
        echo "Error: image file size not specified"
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_BOOT_PART_LABEL" ]; then
        echo "Error: boot partition label not specified"
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_ROOT_PART_LABEL" ]; then
        echo "Error: root partition label not specified"
        exit 1
    fi

    BRICKSTRAP_FAT_START=$(brickstrap_mb_to_sectors 4)
    BRICKSTRAP_EXT_START=$(brickstrap_mb_to_sectors 52)

    echo "Creating $BRICKSTRAP_IMAGE_FILE_NAME from $BRICKSTRAP_TAR_FILE..."

    guestfish -N "$BRICKSTRAP_IMAGE_FILE_NAME"=disk:$BRICKSTRAP_IMAGE_FILE_SIZE -- \
        part-init /dev/sda mbr : \
        part-add /dev/sda primary $BRICKSTRAP_FAT_START $(( $BRICKSTRAP_EXT_START - 1 )) : \
        part-add /dev/sda primary $BRICKSTRAP_EXT_START -1 : \
        part-set-mbr-id /dev/sda 1 0x0b : \
        mkfs fat /dev/sda1 : \
        set-label /dev/sda1 ${BRICKSTRAP_BOOT_PART_LABEL} : \
        mkfs ext4 /dev/sda2 : \
        set-label /dev/sda2 ${BRICKSTRAP_ROOT_PART_LABEL} : \
        mount /dev/sda2 / : \
        mkdir-p /boot/flash : \
        mount /dev/sda1 /boot/flash : \
        tar-in "$BRICKSTRAP_TAR_FILE" / : \

    echo "done"
}

function brickstrap_add_beaglebone_bootloader()
{
    if [ ! -n "$BRICKSTRAP_DOCKER_IMAGE_NAME" ]; then
        echo "Error: docker image not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_IMAGE_FILE_NAME" ]; then
        echo "Error: image file name not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -e "$BRICKSTRAP_IMAGE_FILE_NAME" ]; then
        echo "Error: image file '$BRICKSTRAP_IMAGE_FILE_NAME' does not exist"
        exit 1
    fi

    echo "Writing bootloader files to disk image..."

    # See http://elinux.org/Beagleboard:U-boot_partitioning_layout_2.0
    docker run --rm $BRICKSTRAP_DOCKER_IMAGE_NAME cat "/brickstrap/_beagle-boot/MLO" \
        | dd of="$BRICKSTRAP_IMAGE_FILE_NAME" count=1 seek=1 bs=128k conv=notrunc iflag=fullblock
    docker run --rm $BRICKSTRAP_DOCKER_IMAGE_NAME cat "/brickstrap/_beagle-boot/u-boot.img" \
        | dd of="$BRICKSTRAP_IMAGE_FILE_NAME" count=2 seek=1 bs=384k conv=notrunc iflag=fullblock

    echo "done"
}

case $1 in
    create-tar)
        BRICKSTRAP_DOCKER_IMAGE_NAME=$2
        BRICKSTRAP_TAR_FILE=$3
        brickstrap_create_tar
        ;;
    create-image)
        BRICKSTRAP_TAR_FILE=$2
        BRICKSTRAP_IMAGE_FILE_NAME=$3
         # using < 4GB to fit on *any* ~4GB storage
        BRICKSTRAP_IMAGE_FILE_SIZE=${BRICKSTRAP_IMAGE_FILE_SIZE:-"3800M"}
        BRICKSTRAP_BOOT_PART_LABEL=${BRICKSTRAP_BOOT_PART_LABEL:-"BOOT"}
        BRICKSTRAP_ROOT_PART_LABEL=${BRICKSTRAP_ROOT_PART_LABEL:-"ROOTFS"}
        brickstrap_create_image
        ;;
    add-beagle-bootloader)
        BRICKSTRAP_DOCKER_IMAGE_NAME=$2
        BRICKSTRAP_IMAGE_FILE_NAME=$3
        brickstrap_add_beaglebone_bootloader
        ;;
    *)
        echo "Error: invalid arguments"
        brickstrap_show_usage
        exit 1
        ;;
esac
