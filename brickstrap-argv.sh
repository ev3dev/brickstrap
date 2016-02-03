#!/bin/bash
#
# This file is part of brickstrap.
#
# brickstrap - create a foreign architecture rootfs using kernel namespaces,
#              multistrap, and qemu usermode emulation and create a disk image
#              using libguestfs
#
# Copyright (C) 2016 Johan Ouwerkerk <jm.ouwerkerk@gmail.com>
#

#
# Note: this file is not meant to be executed, source it as a library of
# functions instead. Variables used by the functions (other than stack) are
# namespaced using the 'BR_' or 'BRP_' prefixes. Function names are namespaced
# similarly, using the 'br_' and 'brp_' prefixes. See docs/namespacing.md for
# more information on namespacing in brickstrap.
#

#
# Set a single-valued option, if it hasn't been set already.
# $1: name of the variable to set
# $2: current value of the same.
# $3: new value to set
# $4: failure 'mode' string, values are interpreted as follows:
#       * Starting with '-' implies a commandline option: failure is
#         handled using a combination of 'brp_help' and 'exit 1'
#       * A value of 'error', 'warn', 'info', and 'debug': pass a message
#         to the correspondig logging function and continue silently.
#       * A value of 'fail': log a message and terminates the script.
#       * Any other value implies handling as per default: a message is logged
#         using 'fail' (and the script is terminated), unless the error can be
#         recovered from tivrially by ignoring the new value to set. In that
#         case, a warning message is logged instead and the script continues
#         silently.
# $5: short descriptive 'name' for the setting being altered.
#
function brp_set_single_value_opt()
{
    if [ -z "$3" ]; then
        case "$4" in
        -*)
            brp_help "Empty values are invalid as '$5' setting"
            exit 1
        ;;
        warn|info|error|debug|fail)
            $4 "Empty values are invalid as '$5' setting"
        ;;
        *)  fail "Empty value are invalid as '$5' setting";;
        esac
    elif [ -z "$2" ]; then
        eval "$1=\"$3\""
    elif [ "$2" = "$3" ]; then
        case "$4" in
        -*) warn "Ignoring duplicate value for '$5' setting: $4 '$3'"
        ;;
        warn|info|error|debug|fail)
            $4 "Ignoring duplicate value for '$5' setting: '$3'"
        ;;
        *)  warn "Ignoring duplicate value for '$5' setting: '$3'"
        ;;
        esac
    else
        case "$4" in
        -*)
            brp_help "Duplicate value for '$5' setting: $4 '$3'.
Previous setting: '$2'"
            exit 1
        ;;
        warn|info|error|debug|fail)
            $4 "Duplicate value for '$5' setting: '$3'.
Previous setting: '$2'"
        ;;
        *)  fail "Duplicate value for '$5' setting: '$3'.
Previous setting: '$2'";;
        esac
    fi
}

#
# Append to a multi-valued option (list).
# $1: name of the variable to append to
# $2: current value of the same.
# $3: new value to add
# $4: failure 'mode' string, values are interpreted as follows:
#       * Starting with '-' implies a commandline option: failure is
#         handled using a combination of 'brp_help' and 'exit 1'
#       * A value of 'error', 'warn', 'info', and 'debug': pass a message
#         to the correspondig logging function and continue silently.
#       * A value of 'fail': log a message and terminates the script.
#       * Any other value implies handling as per default: a message is logged
#         using 'fail' (and the script is terminated), unless the error can be
#         recovered from tivrially by ignoring the new value to set. In that
#         case, a warning message is logged instead and the script continues
#         silently.
# $5: short descriptive 'name' for the setting being altered.
#
function brp_set_multi_value_opt()
{
    if [ -z "$3" ]; then
        case "$4" in
        -*)
            brp_help "Empty values are invalid as '$5' setting"
            exit 1
        ;;
        warn|info|error|debug|fail)
            $4 "Empty values are invalid as '$5' setting"
        ;;
        *)  fail "Empty value are invalid as '$5' setting";;
        esac
    elif [ -z "$2" ]; then
        eval "$1=\"'$3'\""
    elif echo "$2" | fgrep -q "'$3'"; then
        case "$4" in
        -*)
            warn "Ignoring duplicate value for '$5' setting: $4 '$3'"
        ;;
        warn|info|error|debug|fail)
            $4 "Ignoring duplicate value for '$5' setting: '$3'"
        ;;
        *)
            warn "Ignoring duplicate value for '$5' setting: '$3'"
        ;;
        esac
    else
        eval "$1=\"$2 '$3'\""
    fi
}

#
# Set up defaults for output destination and image file name.
# This function is meant to be called when the environment is being set up,
# after the project config has been sourced, but before brickstrap starts to
# perform actual work.
#
function brp_set_destination_defaults()
{
    if [ -z "$BR_DESTDIR" ]; then
        BRP_DEFAULT_DESTDIR=$(pwd)
    fi

    if [ -z "$BR_IMAGE_BASE_NAME" ]; then
        BRP_IMAGE_DEFAULT_NAME="$(basename "$(br_dest_dir)")-$(date +%F)"
    fi
}

#
# Sanity check that image names specified on the commandline do not attempt to
# escape their directory. (Note: empty image names are valid).
#
function brp_validate_image_name()
{
    if [ -n "$BR_IMAGE_BASE_NAME" ] &&
        [ "$(basename "$BR_IMAGE_BASE_NAME")" != "$BR_IMAGE_BASE_NAME" ]; then
        fail "Invalid image name (not a valid basename): '$BR_IMAGE_BASE_NAME'"
    fi
}

#
# Look up the destination directory to be used for storing brickstrap output.
#
function br_dest_dir()
{
    if [ -n "$BR_DESTDIR" ]; then
        echo -n "$(readlink -f "$BR_DESTDIR")"
    else
        echo -n "$(readlink -f "$BRP_DEFAULT_DESTDIR")"
    fi
}

#
# Look up the directory containing the local rootfs directory hierarchy.
#
function br_rootfs_dir()
{
    echo -n "$(br_dest_dir)/rootfs"
}

#
# Look up the directory for storing disk image files.
#
function br_image_dir()
{
    echo -n "$(br_dest_dir)/images"
}

#
# Look up the directory for storing meta-data/reports generated during a build.
#
function br_report_dir()
{
    echo -n "$(br_dest_dir)/reports"
}

#
# Look up the basename for output files to generate. This name does not include
# file type suffixes. This function is intended for scripts that need to know
# the basename (pattern) of the image files generated by brickstrap.
#
function br_image_basename()
{
    if [ -n "$BR_IMAGE_BASE_NAME" ]; then
        echo -n "$BR_IMAGE_BASE_NAME"
    else
        echo -n "$BRP_IMAGE_DEFAULT_NAME"
    fi
}

#
# Look up the path to the tarball file containing the rootfs.
#
function br_tarball_path()
{
    echo -n "$(br_dest_dir)/rootfs.tar"
}

#
# Look up the path to a specific disk image, identified by the name of a
# partitioning/imaging scheme and its (file) type extension
# $1: the name of the partitioning/imaging scheme implemented in the disk image
# $2: the file name extension used to identify the disk image type.
#
function brp_image_path()
{
    [ $# -eq 2 -a -n "$1" -a -n "$2" ] && \
        echo -n "$(br_image_dir)/$(brp_image_name "$1" "$2")"
}

#
# Look up the (file) name for a specific disk image, identified by the name of
# a partitioning/imaging scheme and its (file) type extension
# $1: the name of the partitioning/imaging scheme implemented in the disk image
# $2: the file name extension used to identify the disk image type.
#
function brp_image_name()
{
    [ $# -eq 2 -a -n "$1" -a -n "$2" ] && if [ -n "$BR_IMAGE_BASE_NAME" ]; then
        # omit driver name when the image name is configured explicitly (-I)
        echo -n "$BR_IMAGE_BASE_NAME.$2";
    elif [ -n "$BRP_IMAGE_DEFAULT_NAME" ]; then
        # add driver name in the default case, to make workflows involving
        # multiple create-image commands easier
        echo -n "$BRP_IMAGE_DEFAULT_NAME-$1.$2";
    else
        # something is very wrong, presumably brp_set_destination_defaults has
        # not been called yet
        return 1
    fi
}

#
# Look up the path to a directory inside the rootfs for
# the private use by brickstrap. This function returns the path on the host
# filesystem.
#
function br_brp_dir()
{
    echo -n "$(br_rootfs_dir)/$(br_chroot_brp_dir)"
}

#
# Look up the path to a directory inside the rootfs for
# the private use by brickstrap. This function returns the path in the chroot
# filesystem, relative to the root directory (/).
#
function br_chroot_brp_dir()
{
    echo -n "brickstrap"
}

#
# Look up the mount point for the host filesystem inside the chroot (rootfs).
# This function returns the path in the chroot filesystem, relative to the root
# directory (/).
#
function br_chroot_hostfs_dir()
{
    echo -n "$(br_chroot_brp_dir)/host-rootfs"
}

#
# Look up the path to the configuration file for use with multistrap
#
function br_multistrap_conf()
{
    echo -n "$(br_dest_dir)/multistrap.conf"
}

#
# Common, repeated sanity check to make sure the rootfs is available.
#
function brp_check_rootfs_dir()
{
    if [ ! -d "$(br_rootfs_dir)" ]; then
        fail "$(br_rootfs_dir) does not exist."
    fi
}
