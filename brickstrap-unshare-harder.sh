#!/bin/sh

set -e

HAVE_SU=$(which su)
HAVE_SUDO=$(which sudo)
SCRIPT_PATH=$(dirname $(readlink -f "$0"))
USERNS_PRIV_SETTING=""

bail_userns ()
{
    echo "Error: failed to enable unshare()"
    exit 1
}

#
# Helper to toggle kernel policy on whether or not to allow unshare() by normal users.
# This requires elevated permissions, for acquiring them sudo and su are used if available.
# If both are available, using sudo is preferred so the user invoking the script need not know the root password.
#
toggle_userns_setting ()
{
    if [ -n "$HAVE_SUDO" ]; then
        echo "Using sudo ... may require password for '`whoami`'"
        eval "echo '$1' | $HAVE_SUDO tee /proc/sys/kernel/unprivileged_userns_clone 1>/dev/null"
    elif [ -n "$HAVE_SU" ]; then
        echo "Using su ... may require password for 'root'"
        eval "$HAVE_SU -c 'echo $1 > /proc/sys/kernel/unprivileged_userns_clone'"
    else
        echo "Error: need either sudo or su, neither appear to be available (on the PATH)."
        return 1
    fi
}

restore_userns_priv_setting ()
{
    # make sure to pass original exit code (brickstrap.sh) on
    orig=$?
    if [ -n "$USERNS_PRIV_SETTING" ]; then
        echo "Restoring default policy on unshare() for normal users ..."
        toggle_userns_setting "$USERNS_PRIV_SETTING" && return $orig
    else
        return $orig
    fi
}

case "$1" in
    # special case common brickstrap commands which do not require any userns fiddling
    -h) ;;
    *)
        # brickstrap.sh requires at least one argument (command)
        # it will therefore error out if it is missing before it requires userns fiddling
        if [ -n "$1" -a -e /proc/sys/kernel/unprivileged_userns_clone ]; then
            USERNS_PRIV_SETTING=$(cat /proc/sys/kernel/unprivileged_userns_clone)
            if [ "$USERNS_PRIV_SETTING" = "0" ]; then
                echo "Enabling normal user code to unshare() ..."
                toggle_userns_setting 1 || bail_userns
                trap restore_userns_priv_setting EXIT
            fi
        fi
    ;;
esac

"$SCRIPT_PATH/brickstrap.sh" "$@"