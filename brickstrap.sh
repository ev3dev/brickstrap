#!/bin/sh
#
# brickstrap - create a foreign architecture rootfs using multistrap, proot,
#              and qemu usermode emulation
#
# Copyright (C) 2014 by David Lechner <david@lechnology.com>
#
# Based on polystrap:
# Copyright (C) 2011 by Johannes 'josch' Schauer <j.schauer@email.de>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM,OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

usage() {
	echo "Usage: $0: [-e] [-f] [-v] [-n] [-s suite] [-a arch] [-d directory] [-m mirror] [-p packages] platform\n" >&2
}

SCRIPT_PATH=$(dirname $(readlink -f "$0"))

CHROOTQEMUCMD="proot -q qemu-arm -v -1 -0"
CHROOTQEMUBINDCMD=$CHROOTQEMUCMD" -b /dev -b /sys -b /proc"
CHROOTCMD="proot -v -1 -0"

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C
export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

FORCE=""
MSTRAP_SIM=
EXIT_ON_ERROR=true
while getopts efvns:a:d:m:p: opt; do
	case $opt in
	s) _SUITE="$OPTARG";;
	a) _ARCH="$OPTARG";;
	d) _ROOTDIR="$OPTARG";;
	m) _MIRROR="$OPTARG";;
	p) _PACKAGES="$OPTARG";;
	n) MSTRAP_SIM="--simulate";;
	e) EXIT_ON_ERROR=false;;
	v) set -x;;
	f) FORCE=true;;
	?) usage; exit 1;;
	esac
done
shift $(($OPTIND - 1))

[ "$#" -ne 1 ] && { echo "too many positional arguments" >&2; usage; exit 1; }

[ "$EXIT_ON_ERROR" = true ] && set -e

BOARD="$1"

[ ! -r "$BOARD" ] && BOARD="$SCRIPT_PATH/$BOARD"
[ ! -r "$BOARD" ] && { echo "cannot find target directory: $BOARD" >&2; exit 1; }
[ ! -r "$BOARD/multistrap.conf" ] && { echo "cannot read multistrap config: $BOARD/multistrap.conf" >&2; exit 1; }

# source default options
. "$SCRIPT_PATH/default/config"

# overwrite default options by target options
[ -r "$BOARD/config" ] && . "$BOARD/config"

# overwrite target options by commandline options
SUITE=${_SUITE:-$SUITE}
ARCH=${_ARCH:-$ARCH}
ROOTDIR=$(readlink -m ${_ROOTDIR:-$ROOTDIR})
MIRROR=${_MIRROR:-$MIRROR}

if [ "$_PACKAGES" = "" ] && [ -r "$BOARD/packages" ]; then
	# if no packages were given by commandline, read from package files
	for f in $BOARD/packages/*; do
		while read line; do PACKAGES="$PACKAGES $line"; done < "$f"
	done
else
	# otherwise set as given by commandline
	PACKAGES="$_PACKAGES"
fi

echo "I: --------------------------"
echo "I: suite:   $SUITE"
echo "I: arch:    $ARCH"
echo "I: rootdir: $ROOTDIR"
echo "I: mirror:  $MIRROR"
echo "I: pkgs:    $PACKAGES"
echo "I: --------------------------"

[ -e "$ROOTDIR.tar" ] && [ ! "$FORCE" = true ] && { echo "tarball $ROOTDIR.tar still exists" >&2; exit 1; }

# if rootdir exists, either warn and abort or delete and continue
if [ -e "$ROOTDIR" ]; then
	if [ "$FORCE" = true ]; then
		rm -rf $ROOTDIR
	else
		echo "root directory $ROOTDIR still exists" >&2
		exit 1
	fi
fi

multistrapconf_aptpreferences=false
multistrapconf_cleanup=false;

# create multistrap.conf
echo "I: create multistrap.conf"
MULTISTRAPCONF=`tempfile -d . -p multistrap`
echo -n > "$MULTISTRAPCONF"
while read line; do
	eval echo $line >> "$MULTISTRAPCONF"
	if echo $line | grep -E -q "^aptpreferences="
	then
		multistrapconf_aptpreferences=true
	fi
	if echo $line | grep -E -q "^cleanup=true"
	then
		multistrapconf_cleanup=true
	fi
done < $BOARD/multistrap.conf

if [ "$multistrapconf_aptpreferences" = "true" ] && [ "$multistrapconf_cleanup" = "true" ]
then
	echo "W: aptpreferences= option with cleanup=true - apt pinning will not take effect."
fi

# download and extract packages
echo "I: run multistrap" >&2
proot -0 multistrap $MSTRAP_SIM -f "$MULTISTRAPCONF"
[ -z "$MSTRAP_SIM" ] || exit 0

rm -f "$MULTISTRAPCONF"

# copy initial directory tree - dereference symlinks
echo "I: copy initial directory root tree $BOARD/root/ to $ROOTDIR/"
if [ -r "$BOARD/root" ]; then
	cp --recursive --dereference $BOARD/root/* $ROOTDIR/
fi

# call apt-get upgrade so that pinning rules in aptpreferences will take effect
if [ "$multistrapconf_aptpreferences" = "true" ]
then
	echo "I: Running apt-get upgrade to ensure aptpreferences"
	$CHROOTQEMUCMD $ROOTDIR apt-get upgrade --yes --force-yes --download-only
fi

# preseed debconf
echo "I: preseed debconf"
if [ -r "$BOARD/debconfseed.txt" ]; then
	cp "$BOARD/debconfseed.txt" $ROOTDIR/tmp/
	$CHROOTQEMUCMD $ROOTDIR debconf-set-selections /tmp/debconfseed.txt
	rm $ROOTDIR/tmp/debconfseed.txt
fi

# run preinst scripts
for script in $ROOTDIR/var/lib/dpkg/info/*.preinst; do
	[ "$script" = "$ROOTDIR/var/lib/dpkg/info/vpnc.preinst" ] && continue
	echo "I: run preinst script ${script##$ROOTDIR}"
	DPKG_MAINTSCRIPT_NAME=preinst \
	DPKG_MAINTSCRIPT_PACKAGE="`basename $script .preinst`" \
	$CHROOTQEMUBINDCMD $ROOTDIR ${script##$ROOTDIR} install
done

# run dpkg --configure -a twice because of errors during the first run
echo "I: configure packages"
$CHROOTQEMUBINDCMD $ROOTDIR /usr/bin/dpkg --configure -a || $CHROOTQEMUBINDCMD $ROOTDIR /usr/bin/dpkg --configure -a || true

# source hooks
if [ -r "$BOARD/hooks" ]; then
	for f in $BOARD/hooks/*; do
		echo "I: run hook $f"
		. $f
	done
fi

#cleanup
echo "I: cleanup"
rm $ROOTDIR/usr/sbin/policy-rc.d

# need to generate tar inside fakechroot so that absolute symlinks are correct
TARBALL=$(pwd)/$(basename $ROOTDIR).tar.gz
echo "I: create tarball $TARBALL"
$CHROOTQEMUCMD $ROOTDIR tar -cpzf host-rootfs$TARBALL --exclude=host-rootfs /

