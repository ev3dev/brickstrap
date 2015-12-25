#!/bin/sh

set -e

if [ -e /proc/sys/kernel/unprivileged_userns_clone ]; then
    USERNS_PRIV_SETTING=$(cat /proc/sys/kernel/unprivileged_userns_clone)
    echo "Enabling normal user code to unshare(), may require sudo passwd..."
    eval "sudo su -c 'echo 1 > /proc/sys/kernel/unprivileged_userns_clone'"
else
    USERNS_PRIV_SETTING=""
fi

restore_userns_priv_setting ()
{
    if [ -n "$USERNS_PRIV_SETTING" ]; then
        echo "Restoring default policy on unshare() for normal users, may require sudo passwd..."
        eval "sudo su -c 'echo $USERNS_PRIV_SETTING > /proc/sys/kernel/unprivileged_userns_clone'"
    fi
}

trap restore_userns_priv_setting EXIT

SCRIPT_PATH=$(dirname $(readlink -f "$0"))

"$SCRIPT_PATH/brickstrap.sh" "$@"