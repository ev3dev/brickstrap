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
# Execute a command inside a unshare()'d user namespace.
#
function brp_unshare()
{
    [ $# -ge 1 -a -n "$1" ] && "$(br_script_path)/user-unshare" "$@"
}

#
# Emulate a chroot using a unshare()'d user namespace.
#
function br_chroot()
{
    [ $# -ge 1 -a -n "$1" ] && "$(br_script_path)/user-unshare" \
        --mount-host-rootfs="$(br_rootfs_dir)/$(br_chroot_hostfs_dir)" \
        -- chroot "$(br_rootfs_dir)" "$@"
}

#
# Alternative to br_chroot with additional bind mounts for /proc, /sys and /dev
#
function br_chroot_bind()
{
    [ $# -ge 1 -a -n "$1" ] && "$(br_script_path)/user-unshare" \
        --mount-proc="$(br_rootfs_dir)/proc" \
        --mount-sys="$(br_rootfs_dir)/sys" \
        --mount-dev="$(br_rootfs_dir)/dev" \
        --mount-host-rootfs="$(br_rootfs_dir)/$(br_chroot_hostfs_dir)" \
        -- chroot "$(br_rootfs_dir)" "$@"
}

#
# Check if the given architecture corresponds to the 'native' Debian
# architecture of the build machine (build host).
# $1: the architecture to check.
#
function brp_is_native()
{
    [ $# -eq 1 -a -n "$1" ] && if [ "$(dpkg --print-architecture)" = "$1" ]; \
    then
        return 0
    elif [ "$1" = "none" ]; then
        return 0
    else
        return 1
    fi
}

#
# Simple heuristic to check if a binary appears to be a QEMU binary.
# This is useful to be able to flag misconfigured binfmt support.
#
function brp_check_binfmt_is_qemu()
{
    [ $# -eq 1 -a -n "$1" ] && case "$1" in
    */qemu-*) return 0;;
    *) return 1;;
    esac
}

#
# Auto detect whether or not a QEMU is required.
# Use update-binfmts to discover the binfmt module for a 'canary' executable
# which we assume any brickstrap rootfs to contain by default after multistrap.
#
function brp_find_binfmt()
{
    if [ -x /usr/sbin/update-binfmts -a -e "$(br_rootfs_dir)/usr/bin/dpkg" ];
    then
        /usr/sbin/update-binfmts --find "$(br_rootfs_dir)/usr/bin/dpkg"
    else
        return 1
    fi
}

#
# Attempt to translate a possibly ambiguous 'architecture' value
# to a known QEMU interpreter (architecture). This is a compatibility
# measure to paper over the differences between 'Debian' and 'QEMU'
# notions of binary 'architecture'.
# $1: the architecture to translate
#
function brp_resolve_qemu_alias()
{
    [ $# -eq 1 -a -n "$1" ] && case "$1" in
    # Debian armhf, armel arches are just 'arm' to QEMU...
    armhf|armel) echo -n "arm";;
    # Debian 'amd64' architecture is known as 'x86_64' by QEMU
    amd64) echo -n "x86_64";;
    x86) echo -n "i386";;
    *) echo -n "$1";;
    esac
}

#
# Attempt to guess the correct QEMU interpreter from a given
# (possibly ambiguous) architecture.
# $1: the architecture use for finding the right QEMU interpreter
#
function brp_guess_qemu()
{
    [ $# -eq 1 -a -n "$1" ] && \
    if brp_is_native "$1"; then
        return 0
    else
        which "qemu-$(brp_resolve_qemu_alias "$1")-static"
    fi
}

#
# Determine which QEMU interpreter to use. This function implements
# a fallback scheme as follows:
#  - prefer an explicitly configured QEMU (QEMU_STATIC or BR_QEMU)
#  - next, attempt to auto-detect QEMU through binfmt support scripts/tools
#  - finally, guess QEMU based on contents of ARCH, if available
# Returns 0 if no QEMU is required.
# Returns 254 if QEMU was explicitly configured by the user.
# Returns 255 if QEMU was auto-detected.
# BRP_BINFMT is set to the QEMU which is found or to the empty string if no
# emulator is required. Fails if an emulator cannot be determined.
#
function brp_determine_qemu_impl()
{
    BRP_BINFMT=""
    # is BRP_BINFMT configured via environment or commandline option argument?
    if brp_validate_qemu; then
        if [ -n "$BRP_BINFMT" ]; then
            info "Using configured QEMU: '$BRP_BINFMT'"
            return 254
        else
            info "Not using QEMU: configuration indicates it is not required"
        fi
    # is BRP_BINFMT explicitly not configured yet.
    elif brp_auto_detect_qemu; then
        if [ -n "$BRP_BINFMT" ]; then
            info "Using auto-detected QEMU: '$BRP_BINFMT'"
            return 255
        else
            info "Not using QEMU: detected or guessed that it is not required"
        fi
    else
        fail "Unable to determine QEMU!"
    fi
}

function brp_auto_detect_qemu()
{
    BRP_BINFMT=$(brp_find_binfmt)
    if [ $? -eq 0 ]; then
        # double check that the binfmt thingy refers to what appears to be QEMU
        # it could be something silly like a misconfigured binfmt support.
        [ -z "$BRP_BINFMT" ] || brp_check_binfmt_is_qemu "$BRP_BINFMT" || \
            warn "This may not be a QEMU binary after all: '$BRP_BINFMT'.
Check your binfmt configuration and/or configure QEMU to silence this warning."
    else
        # canonical 'ARCH' var is set
        # Fall back to guessing games involving $ARCH
        # Note that this should be considered a 'valid' scenario:
        # 'native' bootstraps strictly do not require binfmt & QEMU to work,
        # therefore relevant packages may not be installed and brickstrap
        # should recover.
        #
        if [ -n "$ARCH" ]; then
            warn "Unable to auto-detect required QEMU based on binfmt support.
Reverting to guessing QEMU; install binfmt-support packages to avoid it."
            BRP_BINFMT=$(brp_guess_qemu "$ARCH")
        # arch not set, report failure of binfmt support mechanism as fatal
        elif [ ! -x /usr/sbin/update-binfmts ]; then
            fail "/usr/sbin/update-binfmts is not executable.
Do you have necessary binfmt packages installed?"
        elif [ ! -e "$(br_rootfs_dir)/usr/bin/dpkg" ]; then
            fail "Unable to locate 'dpkg' in rootfs ($(br_rootfs_dir))."
        else
            fail "/usr/sbin/update-binfmts failed to do its job. Bailing."
        fi
    fi
}

#
# Check whether commandline or environment based configuration of QEMU is
# 'valid', i.e that it corresponds to an existing QEMU interpreter.
# The variable 'BRP_BINFMT' is set to the passed QEMU interpreter if valid.
# Returns 255 if no QEMU was configured. Fails if the QEMU settings are
# misconfigured.
#
function brp_validate_qemu()
{
    # check environment variable first, may have been set by config
    if [ -n "$QEMU_STATIC" -a -x "$QEMU_STATIC" ]; then
        BRP_BINFMT="$(readlink -f $QEMU_STATIC)"
    # try to relate a QEMU_STATIC value to a binary indirectly.
    elif [ -n "$QEMU_STATIC" ] && brp_guess_qemu "$QEMU_STATIC" >/dev/null
    then
        BRP_BINFMT=$(brp_guess_qemu "$QEMU_STATIC")
    # check if BR_QEMU (commandline option) corresponds to a binary
    elif [ -n "$BR_QEMU" -a -x "$BR_QEMU" ]; then
        BRP_BINFMT="$(readlink -f $BR_QEMU)"
    # try to relate a BR_QEMU value to a binary indirectly.
    elif [ -n "$BR_QEMU" ] && brp_guess_qemu "$BR_QEMU" >/dev/null; then
        BRP_BINFMT=$(brp_guess_qemu "$BR_QEMU")
    elif [ -n "$QEMU_STATIC" ]; then
        fail "Unable to determine QEMU from configuration: '$QEMU_STATIC'"
    elif [ -n "$BR_QEMU" ]; then
        fail "Unable to determine QEMU from option argument: '$BR_QEMU'"
    else
        BRP_BINFMT=""
        return 255 # not set
    fi
}

#
# Wrapper around brp_determine_qemu_impl which ensures that the actual logic is
# evaluated only once.
#
function brp_determine_qemu()
{
    if [ -z "$BRP_HOST_QEMU" -a -z "$BRP_ROOTFS_QEMU" ]; then
        brp_determine_qemu_impl || case "$?" in
            254)
                # manually configured QEMU binaries may live in developer home
                # directories or other non-standard locations. Fix up paths
                # inside the chroot to pretend the binaries are from /usr/bin
                #
                BRP_ROOTFS_QEMU="/usr/bin/$(basename "$BRP_BINFMT")"
                BRP_HOST_QEMU="$BRP_BINFMT"
            ;;
            255)
                # system QEMU binary found (or something passing for it anyway)
                # copy it to rootfs, preserving the same path in chroot.
                #
                BRP_ROOTFS_QEMU="$BRP_BINFMT"
                BRP_HOST_QEMU="$BRP_BINFMT"
            ;;
            *)  fail "Unable to determine QEMU!";;
        esac
    fi
}

#
# Look up the path to QEMU binary to use on the host filesystem.
# This function requires the QEMU interpreter has been determined, first.
# See brp_determine_qemu
#
function br_get_host_qemu()
{
    [ -n "$BRP_HOST_QEMU" ] && echo -n "$BRP_HOST_QEMU"
}

#
# Look up the path to QEMU binary to use in the rootfs.
# This function requires the QEMU interpreter has been determined, first.
# Note: the QEMU path is returned without leading slash (/).
# See brp_determine_qemu
#
function br_get_rootfs_qemu()
{
    [ -n "$BRP_ROOTFS_QEMU" ] && echo -n "${BRP_ROOTFS_QEMU##/}"
}

#
# Logic to make sure appropriate QEMU is installed to rootfs.
# This function should be called right after the multistrap has been completed
# successfully.
#
function brp_setup_qemu_in_rootfs()
{
    brp_determine_qemu
    if [ -n "$BRP_BINFMT" ]; then
        mkdir -p "$(br_rootfs_dir)/$(dirname "$(br_get_rootfs_qemu)")" && \
        cp "$(br_get_host_qemu)" "$(br_rootfs_dir)/$(br_get_rootfs_qemu)" || \
            fail "Unable to copy QEMU binary: '$BRP_BINFMT'
From host: $(br_get_host_qemu)
To rootfs: $(br_rootfs_dir)/$(br_get_rootfs_qemu)"
    fi
}
