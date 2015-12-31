#!/bin/bash
#
# This file is part of brickstrap.
#
# brickstrap - create a foreign architecture rootfs using kernel namespaces,
#              multistrap, and qemu usermode emulation and create a disk image
#              using libguestfs

#
# Note: this file is not meant to be executed, source it as a library of functions instead.
# Variables used by the functions (other than stack) are namespaced using the 'BR_' prefix.
# Function names are namespaced similarly, using the 'br_' prefix.
#

#
# Helper function to check that path overlay variables are set to valid values if set.
# These are meant to be called right after options parsing to check passed options/environment vars are sane.
#
#
# Variables are considered 'valid' if unset (empty) or if at least one matching sub-hierarchy for the
# variable can be found on the search path. Alternatively validation can be forced to report 'success' by
# setting corresponding `BR_IGNORE_INVALID_*`.
#

function br_validate_project()
{
    if [ -z "$BR_PROJECT" -a -z "$BR_IGNORE_INVALID_PROJECT" ]; then
        fail "Project required!"
    else
        [ -n "$BR_IGNORE_INVALID_PROJECT" -o -d "$BR_PROJECT" ] || \
        fail "Not a valid project (no such directory): '$BR_PROJECT'"
    fi
}

function br_validate_variant()
{
    [ -z "$BR_VARIANT" ] || \
        [ -n "$BR_IGNORE_INVALID_VARIANT" ] || \
        br_locate_directory "variant/$BR_VARIANT" -d >/dev/null || \
        fail "Not a valid variant (no such directory): '$BR_VARIANT'"
}

function br_validate_board()
{
    [ -z "$BR_BOARD" ] || \
        [ -n "$BR_IGNORE_INVALID_BOARD" ] || \
        br_locate_directory "board/$BR_BOARD" >/dev/null || \
        fail "Not a valid board (no such directory): '$BR_BOARD'"
}

function br_validate_arch()
{
    [ -z "$BR_ARCH" ] || \
        [ -n "$BR_IGNORE_INVALID_ARCH" ] || \
        br_locate_directory "arch/$BR_ARCH" >/dev/null || \
        fail "Not a valid arch (no such directory): '$BR_ARCH'"
}

function br_validate_distro()
{
    [ -z "$BR_DISTRO" ] || \
        [ -n "$BR_IGNORE_INVALID_DISTRO" ] || \
        br_locate_directory "distro/$BR_DISTRO" >/dev/null || \
        fail "Not a valid distro (no such directory): '$BR_DISTRO'"
}

#
# Checks that the environment variables used for path overlays are sane.
# The order in which various variables are checked is significant (for precise error reporting in case of simple typos).
#
function br_validate_search_path_vars()
{
    br_validate_project && br_validate_variant && br_validate_board && br_validate_arch && br_validate_distro
}


#
# Helper functions for path lookup
#


#
# Checks if a path should be 'accepted' and therefore returned by br_check_path.
#
# $1 the path to test
# $2 a well-known path test or arbitrary callback (which will be invoked via eval and passed the path to test).
#    special primitives 'true' and false' are recognised for the purpose of blanket inclusion/exclusion of paths.
#
function br_accept_path_if()
{
    case "$2" in
    -d|-e|-f|-h|-L|-O|-G|-N|-s|-r|-w|-x) test "$2" "$1";; # known good path tests
    true) return 0;; # permit a blanket override of 'true' to accept any path
    false) return 1;; # permit a blanket override of 'false' to disallow any path
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
# $1 path to test
# $2 path test to perform
# $3 optional: pass 'continue' to return with a status code of '255' instead of '0' on success.
#    This mode may be useful in if-else logic to force continued evaluation of subsequent clauses.
#
function br_check_path()
{
    if [ $# -ge 2 ] && br_accept_path_if "$1" "$2"; then
        if [ $# -eq 2 -o "$3" != "continue" ]; then
            echo -n "$1"
            return 0
        else
            echo "$1"
            return 255
        fi
    else
        return 1
    fi
}

#
# Find a distro-specific path.
# Parameters:
# $1 base path to find
# $2 path test to confirm before accepting it (see accept_path_if)
# $3 path prefix/directory on top of which the distro-specific hierarchy is layered.
# $4 optional: pass 'continue' to continue search for acceptable paths once one has been found.
#    This can be used to get all 'available' paths matching the base path and path test.
#
function br_find_distro_path()
{
    if [ $# -lt 3 -o -z "$BR_DISTRO" ] || [ ! -d "$3/distro/$BR_DISTRO" -a -z "$BR_IGNORE_INVALID_DISTRO" ]; then
        return 1
    elif br_check_path "$3/distro/$BR_DISTRO/$1" "$2" "${@:4:$#}"; then
        return 0
    else
        return 1
    fi
}

#
# Find an arch-specific path.
# Parameters:
# $1 base path to find
# $2 path test to confirm before accepting it (see accept_path_if)
# $3 path prefix/directory on top of which the arch-specific hierarchy is layered.
# $4 optional: pass 'continue' to continue search for acceptable paths once one has been found.
#    This can be used to get all 'available' paths matching the base path and path test.
#
function br_find_arch_path()
{
    # todo 'aliasing' for native arch?
    if [ $# -lt 3 -o -z "$BR_ARCH" ] || [ ! -d "$3/arch/$BR_ARCH" -a -z "$BR_IGNORE_INVALID_ARCH" ]; then
        return 1
    elif br_find_distro_path "$1" "$2" "$3/arch/$BR_ARCH" "$4"; then
        return 0
    elif br_check_path "$3/arch/$BR_ARCH/$1" "$2" "$4"; then
        return 0
    else
        return 1
    fi
}

#
# Find a board-specific path.
# Parameters:
# $1 base path to find
# $2 path test to confirm before accepting it (see accept_path_if)
# $3 path prefix/directory on top of which the board-specific hierarchy is layered.
# $4 optional: pass 'continue' to continue search for acceptable paths once one has been found.
#    This can be used to get all 'available' paths matching the base path and path test.
#
function br_find_board_path ()
{
    if [ $# -lt 3 -o -z "$BR_BOARD" ] || [ ! -d "$3/board/$BR_BOARD" -a -z "$BR_IGNORE_INVALID_BOARD" ]; then
        return 1
    elif br_find_arch_path "$1" "$2" "$3/board/$BR_BOARD" "$4"; then
        return 0
    elif br_find_distro_path "$1" "$2" "$3/board/$BR_BOARD" "$4"; then
        return 0
    elif br_check_path "$3/board/$BR_BOARD/$1" "$2" "$4"; then
        return 0
    else
        return 1
    fi
}

#
# Find a variant-specific path.
# Parameters:
# $1 base path to find
# $2 path test to confirm before accepting it (see accept_path_if)
# $3 path prefix/directory on top of which the variant-specific hierarchy is layered.
# $4 optional: pass 'continue' to continue search for acceptable paths once one has been found.
#    This can be used to get all 'available' paths matching the base path and path test.
#
function br_find_variant_path()
{
    if [ $# -lt 3 -o -z "$BR_VARIANT" ] || [ ! -d "$3/variant/$BR_VARIANT" -a -z "$BR_IGNORE_INVALID_VARIANT" ]; then
        return 1
    elif br_find_board_path "$1" "$2" "$3/variant/$BR_VARIANT" "$4"; then
        return 0
    elif br_find_arch_path "$1" "$2" "$3/variant/$BR_VARIANT" "$4"; then
        return 0
    elif br_find_distro_path "$1" "$2" "$3/variant/$BR_VARIANT" "$4"; then
        return 0
    elif br_check_path "$3/variant/$BR_VARIANT/$1" "$2" "$4"; then
        return 0
    else
        return 1
    fi
}

#
# Find a path in the project.
# Parameters:
# $1 base path to find
# $2 path test to confirm before accepting it (see accept_path_if)
# $3 optional: pass 'continue' to continue search for acceptable paths once one has been found.
#    This can be used to get all 'available' paths matching the base path and path test.
#
function br_find_path()
{
    if [ $# -lt 2 -o -z "$BR_PROJECT" ]; then
        return 1
    elif br_find_variant_path "$1" "$2" "$BR_PROJECT" "$3"; then
        return 0
    elif br_find_board_path "$1" "$2" "$BR_PROJECT" "$3"; then
        return 0
    elif br_find_arch_path "$1" "$2" "$BR_PROJECT" "$3"; then
        return 0
    elif br_find_distro_path "$1" "$2" "$BR_PROJECT" "$3"; then
        return 0
    elif br_check_path "$BR_PROJECT/$1" "$2" "$3"; then
        return 0
    elif [ $? -eq 255 ]; then
        return 0
    else
        return 1
    fi
}

#
# Functions to look up a base path matching a given path test.
# This is a more convenient interface around br_find_path.
# Usage var=$(br_locate_path query -r) || echo "error" # checks 'query' resolves to a read-able file
#
# $1
#
function br_locate_path()
{
    [ $# -ge 1 ] && if [ -n "$2" ]; then
        br_find_path "$1" "$2"
    else
        br_find_path "$1" -e
    fi
}

function br_locate_directory()
{
    [ $# -eq 1 ] && br_find_path "$1" -d
}

#
# Functions to generate a list of paths matching a given base path and path test.
# This is a more convenient interface around br_find_path.
#
# The paths may be consumed by piping output into a 'while IFS='' read -r line' block or by using the
# callback interface of br_consume_path_list* functions.
#
# $1 base path to find
# $2 optional: path test or the string 'reverse' if $3 isn't passed.
# $3 optional: pass 'reverse' to reverse the order of the paths in output.
#
function br_list_paths()
{
    [ $# -ge 1 ] && if [ $# -gt 2 -a -n "$3" -a "$3" = "reverse" ]; then
        br_find_path "$1" "$2" "continue" | tac
    elif [ $# -eq 2 -a -n "$2" -a "$2" = "reverse" ]; then
        br_find_path "$1" -e "continue" | tac
    elif [ $# -eq 2 ]; then
        br_find_path "$1" "$2" "continue"
    else
        br_find_path "$1" -e "continue"
    fi
}

#
# Convenience version of br_list_paths which uses a fixed path test of -d (directories)
#
# $1 base path to find
# $2 optional: pass 'reverse' to reverse the order of the paths in output
#
function br_list_directories()
{
    [ $# -ge 1 ] && br_list_paths "$1" -d "$2"
}

#
# Callback interface to consume path lists generated by br_list_*()
#
# br_list_* path ...optional_list_args | br_consume_path_list* call_back_name optional_call_back_args...
#
# The calling convention is:
#
# The callback argument is eval'ed
# The callback is passed the current file being consumed (BR_PATHS_CUR_FILE) as last argument.
# Optional callback args are passed on.
#
# No special handling for spaces-in-arguments is performed, so users of br_consume_path_list* functions
# must make sure any spaces in arguments are properply escaped.
#
# Return code of the callback is captured (if it returns a non-zero status code).
# If previous invocations of the callback failed, the last captured error code will be in BR_PATHS_CB_RETURNCODE
# If any invocation of the callback fails (i.e. returned non-zero status code) or if another error occurs,
# the br_consume_path_list*() function will return with a non-zero return code.
#
# This means something like this will print directories found using a given printf format:
#
# br_list_directories query | br_consume_path_list printf 'found: %s\\n' || echo "error"
#

function br_consume_path_list()
{
    BR_PATHS_CB_RETURNCODE=0
    [ $# -ge 1 -a -n "$1" ] && while IFS='' read -r BR_PATHS_CUR_FILE || [ -n "$BR_PATHS_CUR_FILE" ]; do
        eval "$@ \"$BR_PATHS_CUR_FILE\"" || BR_PATHS_CB_RETURNCODE=$?
    done && return "$BR_PATHS_CB_RETURNCODE"
}

#
# Version of br_consume_path_list which shifts arguments up by one.
# The first argument ($1) should be the same as the one passed to the br_list_* function that was used to generate the
# input to br_consume_path_list_iterate_directories.
# Example usage:
# br_list_directories "$query" | br_consume_path_list_iterate_directories "$query" echo
#
function br_consume_path_list_iterate_directories()
{
    BR_PATHS_CB_RETURNCODE=0
    [ $# -ge 2 -a -n "$1" -a -n "$2" ] && while IFS='' read -r BR_PATHS_CUR_FILE || [ -n "$BR_PATHS_CUR_FILE" ]; do
        for BR_PATHS_CUR_FILE in "$BR_PATHS_CUR_FILE/"*; do
            if [ "$(br_locate_path "$1/`basename $BR_PATHS_CUR_FILE`")" = "$BR_PATHS_CUR_FILE" ]; then
                eval "${@:2:$#} \"$BR_PATHS_CUR_FILE\"" || BR_PATHS_CB_RETURNCODE=$?
            fi
        done
    done && return "$BR_PATHS_CB_RETURNCODE"
}

#
# Debug tools: list paths/search path information.
# Aside from command line argument parsing these are 'complete' sub-programs and may be wired up to respective commands directly.
#

function br_print_path()
{
    br_validate_search_path_vars && if [ -n "$1" ]; then
        info "Locate: '$1'"
        if BR_PATHS_CUR_FILE=$(br_locate_path "$1") && [ -n "$BR_PATHS_CUR_FILE" ]; then
            info "Found: '$BR_PATHS_CUR_FILE'"
            return 0
        else
            info "Not found."
            return 2
        fi
    else
        fail "Path required!"
    fi
}

function br_print_all_paths()
{
    br_validate_search_path_vars && if [ -n "$1" ]; then
        BR_path_prio_count=0
        BR_PATHS_CB_RETURNCODE=""
        info "Find: '$1'"
        br_list_paths "$1" -e "$2" | br_consume_path_list 'br_path_cb() { ((BR_path_prio_count++)); info "[$BR_path_prio_count]: '"'\$1'"'"; }; br_path_cb'

        if [ $? -eq 0 ]; then
            return 0
        elif [ -z "$BR_PATHS_CB_RETURNCODE" ]; then
            info "Not found."
            return 2
        else
            fail "Error occured"
        fi
    else
        fail "Path required!"
    fi
}

function br_print_all_dir_listing()
{
    br_validate_project && if [ -n "$1" ]; then
        BR_path_prio_count=0
        BR_PATHS_CB_RETURNCODE=""
        info "List directories: $1"
        br_list_directories "$1" "$2" | br_consume_path_list_iterate_directories "$1" 'br_path_cb() { ((BR_path_prio_count++)); info "[$BR_path_prio_count]: '"'\$1'"'"; }; br_path_cb'

        if [ $? -eq 0 ]; then
            return 0
        elif [ -z "$BR_PATHS_CB_RETURNCODE" ]; then
            info "Nothing found."
            return 2
        else
            fail "Error occured"
        fi
    else
        fail "Path required!"
    fi
}

function br_print_search_paths()
{
    if [ -n "$BR_PROJECT" ]; then
        BR_path_prio_count=0
        BR_PATHS_CB_RETURNCODE=""
        if [ ! -d "$BR_PROJECT" ]; then
            warn "Invalid project (not a directory): $BR_PROJECT"
            warn "Without a valid project directory as anchor, search path is purely hypothetical and will not actually work."
        fi
        info "List search path:"
        br_list_paths "" 'true' "$1" | br_consume_path_list 'br_path_cb() { ((BR_path_prio_count++)); info "Path[$BR_path_prio_count]: '"'\$1'"'"; }; br_path_cb'

        if [ $? -eq 0 ]; then
            return 0
        elif [ -z "$BR_PATHS_CB_RETURNCODE" ]; then
            info "Empty search path!"
            return 2
        else
            fail "Error occured"
        fi
    else
        fail "Project required!"
    fi
}
