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
# Default image type 'driver'. This function simply delegates to the current
# brickstrap default.
# $1: path to the image file to generate.
#
function brp_image_default_driver()
{
    brp_image_drv_single_fs "$1"
}

#
# Default image type configuration validator. This function simply delegates to
# the current brickstrap default.
#
function brp_validate_default_image_config()
{
    brp_image_drv_check_single_fs
}

#
# Displays an error message if a image type driver failed to create an image
# file successfully. Returns the given status code.
# $1: the status code returned by the driver function
# $2: the name of the partitioning/imaging scheme implemented in the disk image
# $3: the file path of the disk image
#
function brp_image_err_msg()
{
    error "Unable to create image: '$3'.
Driver '$2' ($(brp_get_image_type_driver "$2")) returned status code: $1"
    return $1
}

#
# Create a disk image file (type). This function looks up the
# relevant driver and invokes it with the given path. Before creating the image
# this function checks it does not already exist or, if it does, that it may be
# overwritten.
# $1: the name of the partitioning/imaging scheme implemented in the disk image
#
function brp_create_image_type()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        error "Image type required!"
        return 1
    elif [ -z "$(brp_get_image_type_driver "$1")" ]; then
        error "Unable to create image: '$2'.
No driver for image type: '$1'"
        return 1
    fi
    BRP_CUR_IMG="$(brp_image_path "$1" "$(brp_get_image_type_extension $1)")"
    debug "IMAGE: $BRP_CUR_IMG"
    if [ -z "$BR_FORCE" -a -f "$BRP_CUR_IMG" ]; then
        error "$BRP_CUR_IMG already exists. Use -f option to overwrite."
        return 1
    else
        eval "$(brp_get_image_type_driver "$1")" "$BRP_CUR_IMG" || \
            brp_image_err_msg "$?" "$1" "$BRP_CUR_IMG"
    fi
}

#
# Look up the driver function for a given image type name.
# $1: the name of the partitioning/imaging scheme implemented in the disk image
#
function brp_get_image_type_driver()
{
    [ $# -eq 1 -a -n "$1" ] && case "$1" in
        default)
            echo -n brp_image_default_driver
        ;;
        *)
            eval echo -n "\$BRP_IMG_DRV_REGISTRY_$1"
        ;;
    esac
}

#
# Look up the file type extension for a given image type name.
# $1: the name of the partitioning/imaging scheme implemented in the disk image
#
function brp_get_image_type_extension()
{
    [ $# -eq 1 -a -n "$1" ] && case "$1" in
        default)
            echo -n img
        ;;
        *)
            eval echo -n "\$BRP_IMG_EXT_REGISTRY_$1"
        ;;
    esac
}

#
# Look up the validator function to check image configuration parameters.
# $1: the name of the partitioning/imaging scheme implemented in the disk image
#
function brp_get_image_cfg_validator()
{
    [ $# -eq 1 -a -n "$1" ] && case "$1" in
        default)
            echo -n brp_validate_default_image_config
        ;;
        *)
            eval echo -n "\$BRP_IMG_CFG_VALIDATOR_$1"
        ;;
    esac
}

#
# Register a custom driver with brickstrap for a custom image type.
# $1: the name of the partitioning/imaging scheme implemented in the disk image
# $2: name of the function which will create the image (type), taking the image
#     file path as argument.
# $3: the image file type extension, without leading dot.
# $4: optional: a validator function to check parameters intended for the image
#     driver function in the project configuration.
#
function br_register_image_type()
{
    if [ $# -lt 3 -o -z "$1" -o -z "$2" -o -z "$3" ]; then
        fail "Bad call to br_register_image_type:
Usage: br_register_image_type <name> <driver_func> <ext> [cfg_validator_func]"
    elif [ -z "$(brp_get_image_type_driver "$1")" ]; then
        eval "BRP_IMG_DRV_REGISTRY_$1=$2"
        eval "BRP_IMG_EXT_REGISTRY_$1=$3"
        if [ -n "$4" ]; then
            eval "BRP_IMG_CFG_VALIDATOR_$1=$4"
        fi
    else
        fail "Rejected duplicate driver '$2' for image type: '$1'
Previous setting was: $(brp_get_image_type_driver "$1")"
    fi
}

#
# Validates image driver specific settings in the project configuration.
#
function brp_validate_image_configuration()
{
    if [ -n "$(brp_get_image_cfg_validator "$(br_image_type)")" ]; then
        eval "$(brp_get_image_cfg_validator "$(br_image_type)")"
    fi
}

#
# Creates a disk image for the configured image type.
#
function brp_create_image()
{
    info "Creating image files..."
    debug "TARBALL: $(br_tarball_path)"
    [ ! -f "$(br_tarball_path)" ] && fail "Could not find $(br_tarball_path)"

    mkdir -p "$(br_image_dir)"
    brp_create_image_type "$(br_image_type)"
}

#
# Look up which driver type to use for creating an image.
#
function br_image_type()
{
    if [ -n "$BR_IMAGE_TYPE" ]; then
        echo -n "$BR_IMAGE_TYPE"
    elif [ -n "$DEFAULT_IMAGE_TYPE" ]; then
        echo -n "$DEFAULT_IMAGE_TYPE"
    else
        echo -n default
    fi
}

#
# Convenience version of brp_image_path() so hooks and reporting scripts
# do not need to know how to call it.
#
function br_image_path()
{
    brp_image_path "$(br_image_type)" \
        "$(brp_get_image_type_extension "$(br_image_type)")"
}

#
# Convenience version of brp_image_name() so hooks and reporting scripts
# do not need to know how to call it.
#
function br_image_name()
{
    brp_image_name "$(br_image_type)" \
        "$(brp_get_image_type_extension "$(br_image_type)")"
}
