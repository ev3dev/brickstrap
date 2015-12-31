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
# Quick and dirty 'harness' for testing of brickstrap-paths.sh
# Usage:
#  1. Prepare a directory tree (test case)
#  2. Set up BR_PROJECT, BR_VARIANT, BR_BOARD, BR_ARCH, BR_DISTRO to
#     simulate scenario
#  3. Optionally, set up BR_IGNORE_INVALID_* variables
#  4. Call script with a command to test against the test environment.
#

#
# Mock logging functions
#

function fail()
{
    echo "FATAL: $1" && exit 1
}

function info()
{
    echo "INFO: $1"
}

function warn()
{
    echo "WARNING: $1"
}


. $(dirname $(readlink -f "$0"))/../brickstrap-paths.sh

if [ $# -eq 0 ]; then
    fail "Command required!\nUse: test-env, path, locate, find, dir"
fi

BR_TEST_CMD="$1" && shift 1 && case "$BR_TEST_CMD" in
    test-env)
        br_validate_search_path_vars && info "Environment passes validation."
    ;;
    path) br_print_search_paths "$@";;
    locate) br_print_path "$@";;
    find) br_print_all_paths "$@";;
    dir)  br_print_all_dir_listing "$@";;
    *) fail "Invalid command: '$1'.\nUse: test-env, path, locate, find, dir";;
esac