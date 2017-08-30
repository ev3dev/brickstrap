#!/bin/bash
#
# brickstrap - disk image creation tool
#
# MIT License
#
# Copyright (c) 2016-2017 David Lechner <david@lechnology.com>
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
    echo "    brickstrap create-report <docker-image> <report-directory>"
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

    BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION="$(docker run --rm --user root $BRICKSTRAP_DOCKER_IMAGE_NAME \
        tar --version | head -1 | cut -d\  -f 4)"
    echo "tar $BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION"

    SORTED_VERSION="$(echo "${BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION}"$'\n'"1.28" | sort -V | head -1)"
    if [ "${SORTED_VERSION}" = "1.28" ]; then # BRICKSTRAP_DOCKER_IMAGE_TAR_VERSION >= 1.28
        BRICKSTRAP_TAR_EXCLUDE_OPTION="--exclude-ignore .brickstrap-tar-exclude"
    elif docker run --rm --user root $BRICKSTRAP_DOCKER_IMAGE_NAME test -f /brickstrap/_tar-exclude; then
        BRICKSTRAP_TAR_EXCLUDE_OPTION="--exclude-from /brickstrap/_tar-exclude"
    fi

    # Then create the actual tar archive

    echo "Creating $BRICKSTRAP_TAR_FILE from $BRICKSTRAP_DOCKER_IMAGE_NAME..."

    brickstrap_tar_path=$(readlink -f "$BRICKSTRAP_TAR_FILE")
    brickstrap_tar_dir=$(dirname "$brickstrap_tar_path")
    brickstrap_tar_base=$(basename "$brickstrap_tar_path")

    # create a docker container to persist data between docker commands
    brickstrap_tar_container=$(mktemp brickstrap.XXXXXX --dry-run)
    docker create \
        --name $brickstrap_tar_container \
        --user root \
        --tty \
        $BRICKSTRAP_DOCKER_IMAGE_NAME \
        tail > /dev/null
    trap "docker rm --force $brickstrap_tar_container > /dev/null" EXIT

    docker start $brickstrap_tar_container > /dev/null

    docker exec $brickstrap_tar_container mkdir -p /brickstrap/_tar-out
    docker exec $brickstrap_tar_container \
        tar --create \
            --one-file-system \
            --preserve-permissions \
            --exclude '.dockerenv' \
            --exclude './brickstrap' \
            --exclude './dev/*' \
            --exclude './sys/*' \
            --exclude './proc/*' \
            --exclude './tmp/*' \
            $BRICKSTRAP_TAR_EXCLUDE_OPTION \
            --file "/brickstrap/_tar-out/$brickstrap_tar_base" \
            --directory "/" \
            .

    echo "done"


    # There can be extra files that need to get added to the archive

    if docker exec $brickstrap_tar_container test -d "/brickstrap/_tar-only"; then
        echo 'Appending /brickstrap/_tar-only/*'
        docker exec $brickstrap_tar_container \
            tar --append \
                --preserve-permissions \
                --file "/brickstrap/_tar-out/$brickstrap_tar_base" \
                --directory "/brickstrap/_tar-only" \
                .
        echo "done"
    fi


    # Finally, move the tar archive from the docker container to the host $PWD

    echo "Copying $brickstrap_tar_base to $brickstrap_tar_dir ..."

    docker cp \
        $brickstrap_tar_container:"/brickstrap/_tar-out/$brickstrap_tar_base" \
        "$brickstrap_tar_dir"

    echo "done"
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
    docker run --rm --user root $BRICKSTRAP_DOCKER_IMAGE_NAME cat "/brickstrap/_beagle-boot/MLO" \
        | dd of="$BRICKSTRAP_IMAGE_FILE_NAME" count=1 seek=1 bs=128k conv=notrunc iflag=fullblock
    docker run --rm --user root $BRICKSTRAP_DOCKER_IMAGE_NAME cat "/brickstrap/_beagle-boot/u-boot.img" \
        | dd of="$BRICKSTRAP_IMAGE_FILE_NAME" count=2 seek=1 bs=384k conv=notrunc iflag=fullblock

    echo "done"
}

function brickstrap_create_report()
{
    if [ ! -n "$BRICKSTRAP_DOCKER_IMAGE_NAME" ]; then
        echo "Error: docker image not specified"
        brickstrap_show_usage
        exit 1
    fi

    if [ ! -n "$BRICKSTRAP_REPORT_DIR_NAME" ]; then
        echo "Error: report directory name not specified"
        brickstrap_show_usage
        exit 1
    fi

    echo "Creating reports..."

    brickstrap_report_dir="$(readlink -f $BRICKSTRAP_REPORT_DIR_NAME)"


    # create a docker container to persist data between docker commands

    brickstrap_report_container=$(mktemp brickstrap.XXXXXX --dry-run)
    docker create \
        --name $brickstrap_report_container \
        --user root \
        --env BRICKSTRAP_DOCKER_IMAGE_NAME="$BRICKSTRAP_DOCKER_IMAGE_NAME" \
        --tty \
        "$BRICKSTRAP_DOCKER_IMAGE_NAME" \
        tail > /dev/null
    trap "docker rm --force $brickstrap_report_container > /dev/null" EXIT

    docker start $brickstrap_report_container > /dev/null


    # Run the report scripts in the image

    docker exec $brickstrap_report_container \
        mkdir -p /brickstrap/_report/_out
    docker exec \
        $brickstrap_report_container \
        find /brickstrap/_report \
            -executable -a -type f -exec echo "Running" {} "..." \; -exec {} \;


    # copy the output directory to the host directory

    docker cp \
        "$brickstrap_report_container":/brickstrap/_report/_out/. \
        "$brickstrap_report_dir"

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
        BRICKSTRAP_IMAGE_FILE_SIZE=${BRICKSTRAP_IMAGE_FILE_SIZE:-"3600M"}
        BRICKSTRAP_BOOT_PART_LABEL=${BRICKSTRAP_BOOT_PART_LABEL:-"BOOT"}
        BRICKSTRAP_ROOT_PART_LABEL=${BRICKSTRAP_ROOT_PART_LABEL:-"ROOTFS"}
        brickstrap_create_image
        ;;
    add-beagle-bootloader)
        BRICKSTRAP_DOCKER_IMAGE_NAME=$2
        BRICKSTRAP_IMAGE_FILE_NAME=$3
        brickstrap_add_beaglebone_bootloader
        ;;
    create-report)
        BRICKSTRAP_DOCKER_IMAGE_NAME=$2
        BRICKSTRAP_REPORT_DIR_NAME=$3
        brickstrap_create_report
        ;;
    *)
        echo "Error: invalid arguments"
        brickstrap_show_usage
        exit 1
        ;;
esac
