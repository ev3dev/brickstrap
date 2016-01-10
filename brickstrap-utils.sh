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
        --mount-host-rootfs="${ROOTDIR}/host-rootfs" \
        -- chroot "${ROOTDIR}" "$@"
}

#
# Alternative to br_chroot with additional bind mounts for /proc, /sys and /dev
#
function br_chroot_bind()
{
    [ $# -ge 1 -a -n "$1" ] && "$(br_script_path)/user-unshare" \
        --mount-proc="${ROOTDIR}/proc" \
        --mount-sys="${ROOTDIR}/sys" --mount-dev="${ROOTDIR}/dev" \
        --mount-host-rootfs="${ROOTDIR}/host-rootfs" \
        -- chroot "${ROOTDIR}" "$@"
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
    elif [ "$1" = "native" ]; then
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
    if [ -x /usr/sbin/update-binfmts -a -e "${ROOTDIR}/usr/bin/dpkg" ]; then
        echo -n "$(/usr/sbin/update-binfmts --find "${ROOTDIR}/usr/bin/dpkg")"
    else
        return 1
    fi
}

#
# Attempt to translate a possibly ambiguous 'ARCH' or 'BR_ARCH' value
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
    elif
        which "qemu-$(brp_resolve_qemu_alias "$1")-static"
    fi
}

#
# Determine which QEMU interpreter to use. This function implements
# a fallback scheme as follows:
#  - prefer an explicitly configured QEMU (QEMU_STATIC or BR_QEMU)
#  - next, attempt to auto-detect QEMU through binfmt support scripts/tools
#  - finally, guess QEMU based on contents of ARCH, if available
# Returns 1 if QEMU was explicitly configured by the user.
# Fails if no QEMU can be determined.
#
function brp_determine_qemu()
{
    BRP_BINFMT=$(brp_validate_qemu)

    # was BRP_BINFMT configured via environment or commandline option argument?
    if [ $? -eq 0 ]; then
        if [ -n "$BRP_BINFMT" ]; then
            echo -n "$BRP_BINFMT"
            return 1
        else # explicit 'native' configuration.
            return 0
        fi
    fi

    BR_BINFMT=$(brp_find_binfmt)
    if [ $? -eq 0 ]; then
        # double check that the binfmt thingy refers to what appears to be QEMU
        # it could be something silly like a misconfigured binfmt support.
        [ -z "$BR_BINFMT" ] || brp_check_binfmt_qemu "$BR_BINFMT" || \
            warn "This may not be a QEMU binary after all: '$BR_BINFMT'.
Check your binfmt configuration and/or configure QEMU to silence this warning."
        echo -n "$BR_BINFMT"
        return 0
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
            brp_guess_qemu "$ARCH"
        # arch not set, report failure of binfmt support mechanism as fatal
        elif [ ! -x /usr/sbin/update-binfmts ]; then
            fail "/usr/sbin/update-binfmts is not executable.
Do you have necessary binfmt packages installed?"
        elif [ ! -e "${ROOTDIR}/usr/bin/dpkg" ]; then
            fail "Unable to locate 'dpkg' in rootfs ($ROOTDIR)."
        else
            fail "/usr/sbin/update-binfmts failed to do its job. Bailing."
        fi
    fi
}

#
# Check whether commandline or environment based configuration of QEMU is
# 'valid', i.e that it corresponds to an existing QEMU interpreter.
# Returns 1 if no QEMU was set, to signal brp_determine_qemu
# Fails if QEMU is explicitly misconfigured.
#
function brp_validate_qemu()
{
    # check environment variable first, may have been set by config
    if [ -n "$QEMU_STATIC" -a -x "$QEMU_STATIC" ]; then
        echo -n "$(readlink -f $QEMU_STATIC)"
    # check if BR_QEMU (commandline option) corresponds to a binary
    elif [ -n "$BR_QEMU" -a -x "$BR_QEMU" ]; then
        echo -n "$(readlink -f $BR_QEMU)"
    # try to relate a BR_QEMU value to a binary indirectly.
    elif [ -n "$BR_QEMU" ]; then
        BRP_BINFMT=$(brp_quess_qemu "$BR_QEMU")
        if [ $? -eq 0 ]; then
            echo -n "$BR_BINFMT"
        else
            fail "Unable to determine QEMU for option argument: '$BR_QEMU'"
        fi
    else
        return 1 # not set
    fi
}

#
# Copy utility to install QEMU to the rootfs
# $1: path to install the binary to, viewed from inside the chroot of ROOTDIR
# $2: path to the binary to copy, viewed from the host system
#
function brp_copy_qemu_to_rootfs()
{
    [ $# -eq 2 -a -n "$1" -a -n "$2" -a -r "$2" ] && \
        mkdir -p "${ROOTDIR}$(dirname "$1")" && \
        cp "$2" "${ROOTDIR}$1" && QEMU_STATIC="$1"
}

#
# Logic to make sure appropriate QEMU is installed to rootfs.
# This function should be called right after the multistrap has been completed
# successfully.
#
function brp_setup_qemu_in_rootfs()
{
    BRP_BINFMT=$(brp_determine_qemu)
    # system QEMU binary found (or something passing for it anyway)
    # copy it to rootfs, preserving the same path in chroot.
    if [ $? -eq 0 -a -n "$BRP_BINFMT" ];
        brp_copy_qemu_to_rootfs "$BRP_BINFMT" "$BRP_BINFMT" || \
            fail "Unable to copy QEMU binary: '$BRP_BINFMT'"
    #
    # manually configured QEMU binaries may live in developer home directories
    # or other non-standard locations. Fix up paths inside the chroot to
    # pretend the binaries are from /usr/bin instead
    #
    elif [ -n "$BRP_BINFMT" ];
        brp_copy_qemu_to_rootfs \
            "/usr/bin/$(basename "$BRP_BINFMT")" \
            "$BRP_BINFMT" || \
            fail "Unable to copy QEMU binary: '$BRP_BINFMT'"
    else
        fail "Unable to determine QEMU!"
    fi
}