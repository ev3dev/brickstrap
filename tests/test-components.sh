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
# Quick and dirty 'harness' for testing of brickstrap-components.sh
# Usage:
#  1. Prepare a directory tree (test case)
#  2. Set up BR_PROJECT, BR_COMPONENTS
#  3. Call script with a command to test against the test environment.
#

set -e
set -o pipefail

function br_script_path()
{
    SCRIPT_PATH=$(readlink -f "$0")
    SCRIPT_PATH=$(dirname "$SCRIPT_PATH")
    echo -n "$SCRIPT_PATH"
}

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

function brt_test_path()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        fail "Path required!"
    elif br_list_paths "$@" >/dev/null; then
        info "Found: '$1'"
    else
        fail "Not found: '$1'"
    fi
}

function brt_test_env()
{
    brp_validate_project_name && brp_validate_component_names && \
            info "Environment passes validation."
}

function brt_test_cat()
{
    if [ $# -ge 1 -a -n "$1" ]; then
        br_cat_files "$1" || fail "Not found: '$1'"
    else
        fail "Path required!"
    fi
}

function brt_test_ls()
{
    if [ $# -ge 1 -a -n "$1" ]; then
        info "Listing paths for query: '$@'"
        br_for_each_path \
            "$(br_list_paths "$@")" \
            "printf ' -- %s\\n'" \
            || fail "Not found: '$1'"
    else
        fail "Path required!"
    fi
}

function brt_test_dir()
{
    if [ $# -ge 1 -a -n "$1" ]; then
        info "Listing component files from: '$1'"
        br_for_each_path_iterate_directories \
            "$(br_list_directories "$1")" \
            "printf ' -- %s\\n'" \
            || fail "No such directory!"
    else
        fail "Directory required!"
    fi
}


. $(dirname $(readlink -f "$0"))/../brickstrap-components.sh

if [ $# -eq 0 ]; then
    fail "Command required!
Use: test-env, test-path, ls, cat, dir"
fi

BR_TEST_CMD="$1" && shift 1 && case "$BR_TEST_CMD" in
    test-env) brt_test_env;;
    test-path) brt_test_env && brt_test_path "$@";;
    ls) brt_test_env && brt_test_ls "$@";;
    cat) brt_test_env && brt_test_cat "$@";;
    dir)  brt_test_env && brt_test_dir "$@";;
    *) fail "Invalid command: '$BR_TEST_CMD'.
Use: test-env, test-path, ls, cat, dir";;
esac
