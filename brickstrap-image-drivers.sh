#!/bin/bash
#
# This file is part of brickstrap.
#
# brickstrap - create a foreign architecture rootfs using kernel namespaces,
#              multistrap, and qemu usermode emulation and create a disk image
#              using libguestfs
#
# Copyright (C) 2016 Johan Ouwerkerk <jm.ouwerkerk@gmail.com>
# Copyright (C) 2016 David Lechner <david@lechnology.com>
#

#
# Note: this file is not meant to be executed, source it as a library of
# functions instead. Variables used by the functions (other than stack) are
# namespaced using the 'BR_' or 'BRP_' prefixes. Function names are namespaced
# similarly, using the 'br_' and 'brp_' prefixes. See docs/namespacing.md for
# more information on namespacing in brickstrap.
#

#
# This file provides driver functions for default image types supported by
# brickstrap.
#


#
# Implement a single root file system partition scheme.
# This function creates a MBR type image (type extension: img).
# $1: path to the image file to generate.
#
function brp_image_drv_single_fs()
{
    debug "IMAGE_FILE_SIZE: ${IMAGE_FILE_SIZE}"
    debug "ROOT_PART_NAME: ${ROOT_PART_NAME}"

    [ $# -eq 1 -a -n "$1" ] && guestfish -N \
        "$1"=fs:ext4:${IMAGE_FILE_SIZE} \
        set-label /dev/sda1 ${ROOT_PART_NAME} : \
        mount /dev/sda1 / : \
        tar-in "$(br_tarball_path)" / : \

}

#
# Sanity checks configuration variables for brp_image_drv_single_fs
#
# Variables:
# ROOT_PART_NAME: Label of root partition. Default: ROOTFS
# IMAGE_FILE_SIZE: The size of the entire image file. Default: 3800M
#
function brp_image_drv_check_single_fs()
{
    ROOT_PART_NAME=${ROOT_PART_NAME:-ROOTFS}
    IMAGE_FILE_SIZE=${IMAGE_FILE_SIZE:-3800M}

    brp_validate_ext_label ROOT_PART_NAME
}

#
# Implement a boot+root partition scheme.
# This function creates a 'boot+root' MBR type image (type extension: img).
# $1: path to the image file to generate.
#
function brp_image_drv_bootroot()
{
    debug "IMAGE_FILE_SIZE: ${IMAGE_FILE_SIZE}"
    [ $# -eq 1 -a -n "$1" ] && guestfish -N \
        "$1"=bootroot:vfat:ext4:${IMAGE_FILE_SIZE}:48M:mbr \
        part-set-mbr-id /dev/sda 1 0x0b : \
        set-label /dev/sda2 EV3_FILESYS : \
        mount /dev/sda2 / : \
        tar-in "$(br_tarball_path)" / : \
        mkdir-p /media/mmc_p1 : \
        mount /dev/sda1 /media/mmc_p1 : \
        glob mv /boot/flash/* /media/mmc_p1/ : \

    # Hack to set the volume label on the vfat partition since guestfish does
    # not know how to do that. Must be null padded to exactly 11 bytes.
    echo -e -n "EV3_BOOT\0\0\0" | \
        dd of="$1" bs=1 seek=32811 count=11 conv=notrunc >/dev/null 2>&1
}


#
# Create a disk image with MBR partition table and 4 partitions. There are two
# identical rootfs partitions to allow for failover and live upgrades.
# ------------------------------------------------------------------------------
# part | label              | mount point | fs   | size
# ------------------------------------------------------------------------------
#    1 | ${BOOT_PART_NAME}  | /boot/flash | VFAT | 48MB
#    2 | ${ROOT_PART_NAME}1 | /           | ext4 | ${ROOT_PART_SIZE}
#    3 | ${ROOT_PART_NAME}2 | /mnt/root2  | ext4 | ${ROOT_PART_SIZE}
#    4 | ${DATA_PART_NAME}  | /var        | ext4 | ${IMAGE_FILE_SIZE} -
#      |                    |             |      | 2 * ${ROOT_PART_SIZE} - 48MB
# ------------------------------------------------------------------------------
#
# $1: path to the image file to generate.
#
function brp_image_drv_redundant_rootfs_w_data()
{
    [ $# -eq 1 -a -n "$1" ] && guestfish -N "$1"=disk:${IMAGE_FILE_SIZE} -- \
        part-init /dev/sda mbr : \
        part-add /dev/sda primary 0 $(brp_to_sector 48) : \
        part-add /dev/sda primary $(brp_to_sector 48) $(brp_to_sector ${ROOT_PART_SIZE}) : \
        part-add /dev/sda primary $(brp_to_sector ${ROOT_PART_SIZE}) $(brp_to_sector $(( 2 * ${ROOT_PART_SIZE} ))) : \
        part-add /dev/sda primary $(brp_to_sector $(( 2 * ${ROOT_PART_SIZE} ))) -1 : \
        part-set-mbr-id /dev/sda 1 0x0b : \
        mkfs fat /dev/sda1 : \
        set-label /dev/sda1 ${BOOT_PART_NAME} : \
        mkfs ext4 /dev/sda2 : \
        set-label /dev/sda2 ${ROOT_PART_NAME}1 : \
        mkfs ext4 /dev/sda3 : \
        set-label /dev/sda3 ${ROOT_PART_NAME}2 : \
        mkfs ext4 /dev/sda4 : \
        set-label /dev/sda4 ${DATA_PART_NAME} : \
        mkdir-p /boot/flash : \
        mount /dev/sda1 /boot/flash : \
        mount /dev/sda2 / : \
        mkdir-p /mnt/root2
        mount /dev/sda3 /var : \
        mkdir-p /var : \
        mount /dev/sda4 /var : \
        tar-in "$(br_tarball_path)" / : \
        umount /boot/flash : \
        umount /var : \
        glob cp-a /* /mnt/root2/ : \

}

#
# Sanity checks configuration variables for the redundant rootfs + data image
# type. If variables aren't defined a default is set.
#
# Variables:
# BOOT_PART_NAME: Label of boot partition. Default: BOOT
# ROOT_PART_NAME: Label of root partition. Default: ROOTFS
# DATA_PART_NAME: Label of root partition. Default: DATA
# IMAGE_FILE_SIZE: The size of the entire image file. Default: 3800M
#
function brp_image_drv_check_redundant_rootfs_w_data()
{

    BOOT_PART_NAME=${BOOT_PART_NAME:-BOOT}
    ROOT_PART_NAME=${ROOT_PART_NAME:-ROOTFS}
    DATA_PART_NAME=${DATA_PART_NAME:-DATA}
    IMAGE_FILE_SIZE=${IMAGE_FILE_SIZE:-3800M}

    brp_validate_fat_label BOOT_PART_NAME

    # appending 1/2 to ROOT_PART_NAME, so 16 characters total
    [ ${#ROOT_PART_NAME} -gt 15 ] && \
        fail "ROOT_PART_NAME cannot be more than 15 characters."
    brp_validate_ext_label ROOT_PART_NAME

    brp_validate_ext_label DATA_PART_NAME
}

#
# Registers the default drivers. To be invoked by brickstrap early before doing
# any option parsing etc.
#
function brp_image_drv_register_defaults()
{
    br_register_image_type single brp_image_drv_single_fs \
        img brp_image_drv_check_single_fs
    br_register_image_type bootroot brp_image_drv_bootroot \
        img # no validation required for bootroot, yet
    br_register_image_type redundant brp_image_drv_redundant_rootfs_w_data \
        img brp_image_drv_check_redundant_rootfs_w_data
}

### Utility Functions
#####################################################################

#
# Check that a variable is a valid FAT partition label.
# See https://en.wikipedia.org/wiki/Label_%28command%29
#
# Parameters:
# $1: the name of the variable to check
#
brp_validate_fat_label()
{
    eval value=\$$1

    [ ${#value} -gt 11 ] && \
        fail "$1=$value cannot be more than 11 characters."

    echo ${value} | egrep -q '^[A-Z0-9_-]*$' || \
        fail "$1=$value contains invalid characters"
}

#
# Check that a variable is a valid ext partition label.
#
# Parameters:
# $1: the name of the variable to check
#
brp_validate_ext_label()
{
    eval value=\$$1

    [ ${#value} -gt 16 ] && \
        fail "$1=$value cannot be more than 16 characters."

    echo ${value} | egrep -q '^[a-zA-Z0-9_-]*$' || \
        fail "$1=$value contains invalid characters"
}

#
# Convert megabytes to sectors. Sectors are assumed to be 512 bytes big.
# $1 is size in megabytes.
#
function brp_to_sector()
{
    #echo $(( $1 * 1024 * 1024 / 512 ))
    echo $(( $1 * 2048 ))
}

