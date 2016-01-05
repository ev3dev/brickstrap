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
# Validates the project name configured (via commandline arguments).
# Additionally it sets another variable that contains the full path to the
# project directory (to be able to distinguish between user input and what
# brickstrap actually uses internally). See also: br_project_dir().
#
function brp_validate_project_name()
{
    if [ -z "$BR_PROJECT" ]; then
        fail "No project specified (project name must not be empty)"
    elif [ -r "$BR_PROJECT" -a -d "$BR_PROJECT" ]; then
        BR_PROJECT_DIR=$(readlink -f "$BR_PROJECT")
    elif [ -r "$(br_script_path)/$BR_PROJECT" ] && \
        [ -d "$(br_script_path)/$BR_PROJECT" ]; then
        BR_PROJECT_DIR=$(readlink -f "$(br_script_path)/$BR_PROJECT")
    else
        fail "Invalid project name (no such directory): '$BR_PROJECT'.
Directory does not exist: '$BR_PROJECT'
Directory does not exist: '$(br_script_path)/$BR_PROJECT'"
    fi
}

#
# Retrieve the absolute path to the project directory. This function maps
# a validated project name to the full path of the project directory.
# This function may be called once the project name has been validated; see
# brp_validate_project_name().
#
function br_project_dir()
{
    [ -n "$BR_PROJECT_DIR" ] && echo -n "$BR_PROJECT_DIR"
}

#
# Check that a given component name is valid. Valid component names correspond
# to an existing subdirectory within the project directory.
# This function requires that the project name has been successfully validated.
# $1 the component name to check.
#
function brp_validate_component_name()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        fail "No component specified (component name must not be empty)"
    elif [ ! -d "$(br_project_dir)/${1##/}" ]; then
        fail "Not a valid component name: '$1'.
Directory does not exist: '$(br_project_dir)/${1##/}'."
    fi
}

#
# Validate the configured component names (from commandline arguments).
# This function requires that the project name has been successfully validated
# first. See also: brp_validate_project_name().
#
function brp_validate_component_names()
{
    brp_iterate_components brp_validate_component_name || \
        fail "At least one component is required"
}

#
# Iterate over the configured component names (commandline arguments), invoking
# callback for each component name. The calling convention is such that the
# component name is passed as first argument to the callback, and any extra
# arguments passed to this function are passed along to the callback aftet the
# component name.
#
# $1: the callback to invoke.
# $2...: optional: additional arguments passed to the callback following the
#                  component name.
#
function brp_iterate_components()
{
    if [ -z "$BR_COMPONENTS" -o $# -eq 0 -o -z "$1" ]; then
        return 1
    else
        BR_PATHS_CB_RETURNCODE=0
        for BRP_PATHS_CUR_FILE in $BR_COMPONENTS; do
            eval "BRP_PATHS_CUR_FILE=$BRP_PATHS_CUR_FILE" # unwraps quotes
            "$1" "${BRP_PATHS_CUR_FILE##/}" "${@:2:$#}" || \
                BR_PATHS_CB_RETURNCODE=$?
        done && return "$BR_PATHS_CB_RETURNCODE"
    fi
}

#
# Helper functions for path lookup
#

#
# Checks if a path should be 'accepted' and therefore returned by br_check_path
#
# $1 the path to test
# $2 a well-known path test or arbitrary callback (which will be invoked via
#    eval and passed the path to test). Special primitives 'true' and false'
#    are recognised for the purpose of blanket inclusion/exclusion of paths.
#
function brp_accept_path_if()
{
    case "$2" in
    # known good path tests
    -d|-e|-f|-h|-L|-O|-G|-N|-s|-r|-w|-x) test "$2" "$1";;
    # permit a blanket override of 'true' to accept any path
    true) return 0;;
    # permit a blanket override of 'false' to disallow any path
    false) return 1;;
    *)
        # premit arbitrary path tests through a callback interface
        # this can be used to reject files based on e.g. a static blacklist
        if [ -n "$2" ]; then
            eval "$2" "$1" || return 1
        else
            return 1
        fi
    ;;
    esac
}

#
# Checks a path against a path test, and if the test succeeds outputs the path.
#
# $1 component to test
# $2 base path to test
# $3 path test to perform
#
function brp_check_path()
{
    if [ $# -ge 3 ] && brp_accept_path_if "$(br_project_dir)/$1/$2" "$3"; then
        echo "$(readlink -f "$(br_project_dir)/$1/$2")"
        return 255
    else
        return 0
    fi
}

#
# Functions to generate a list of paths matching a given base path and path
# test.
#
# The paths may be consumed by piping output into a 'while IFS='' read -r line'
# block or by using the callback interface of br_for_each_path* functions.
#
# $1 base path to find
# $2 optional: path test. If not specified, a default test of '-e' is assumed.
#
function br_list_paths()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        return 1
    fi
    if [ $# -eq 1 ]; then
        brp_iterate_components brp_check_path "$1" -e
    elif [ -n "$2" ]; then
        brp_iterate_components brp_check_path "$@"
    else
        return 1
    fi
    if [ $? -eq 255 ]; then
        return 0
    else
        return 1
    fi
}

#
# Convenience version of br_list_paths which uses a fixed path test of '-d'.
#
# $1 base path to find
#
function br_list_directories()
{
    [ $# -ge 1 ] && br_list_paths "$1" -d
}

#
# Callback interface to consume path lists generated by br_list_*(). Usage:
#
# br_for_each_path* "$(br_list_* path ...optional_list_args)" \
#     call_back_name optional_call_back_args...
#
# The calling convention is:
#
# The callback argument is eval'ed; the callback is passed the current file
# being consumed (BR_PATHS_CUR_FILE) as last argument. Optional callback args
# are passed on.
#
# No special handling for spaces-in-arguments is performed, so users of
# br_for_each_path* functions must make sure any spaces in arguments are
# properply escaped.
#
# Return code of the callback is captured (if non-zero). If previous
# invocations of the callback failed, the last captured error code will be
# saved in BR_PATHS_CB_RETURNCODE. If any invocations of the callback fail
# (i.e. returned non-zero status code) or if another error occurs, the
# br_for_each_path*() function will return with a non-zero return code.
#
# This means something like this will print directories found using a given
# 'printf' format:
#
#  br_for_each_path "$(br_list_directories "$query")" printf 'found: %s\\n' \
#      || echo "error"
#

function br_for_each_path()
{
    BR_PATHS_CB_RETURNCODE=0
    [ $# -ge 2 -a -n "$1" -a -n "$2" ] && \
    while IFS='' read -r BRP_PATHS_CUR_FILE || [ -n "$BRP_PATHS_CUR_FILE" ]; do
        eval "${@:2:$#} \"$BRP_PATHS_CUR_FILE\"" || BR_PATHS_CB_RETURNCODE=$?
    done <<< "$1" && return "$BR_PATHS_CB_RETURNCODE"
}

#
# Version of br_for_each_path() which iterates over directories, invoking a
# callback on items found within it. Use with: br_list_directories().
# For example:
#
# br_for_each_path_iterate_directories "$(br_list_directories "$query")" echo
#
function br_for_each_path_iterate_directories()
{
    BR_PATHS_CB_RETURNCODE=0
    [ $# -ge 2 -a -n "$1" -a -n "$2" ] && \
    while IFS='' read -r BRP_PATHS_CUR_FILE || [ -n "$BRP_PATHS_CUR_FILE" ]; do
        for BRP_PATHS_CUR_FILE in "$BRP_PATHS_CUR_FILE/"*; do
            eval "${@:2:$#} \"$BRP_PATHS_CUR_FILE\"" || BR_PATHS_CB_RETURNCODE=$?
        done
    done <<< "$1" && return "$BR_PATHS_CB_RETURNCODE"
}

#
# Convenience function which concatenates files matching a given base path.
#
# $1 base path of the files to concatenate
#
function br_cat_files()
{
    br_for_each_path "$(br_list_paths "$1" -f)" cat
}
