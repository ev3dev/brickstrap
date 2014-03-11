#!/bin/sh
#
# polystrap - create a foreign architecture rootfs using multistrap, fakeroot,
#             fakechroot and qemu usermode emulation
#
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
	echo "Usage: $0: [-f] [-v] [-n] [-s suite] [-a arch] [-d directory] [-m mirror] [-p packages] platform\n" >&2
}

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C
export PATH=$PATH:/usr/sbin:/sbin

if [ "$FAKEROOTKEY" = "" ]; then
	echo "I: re-executing script inside fakeroot"
	fakeroot "$0" "$@";
	exit
fi

FORCE=""
MSTRAP_SIM=
EXIT_ON_ERROR=true
while getopts efvs:a:d:m:p:n opt; do
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

[ ! -r "$BOARD" ] && { echo "cannot find target directory: $BOARD" >&2; exit 1; }
[ ! -r "$BOARD/multistrap.conf" ] && { echo "cannot read multistrap config: $BOARD/multistrap.conf" >&2; exit 1; }

# source default options
. "default/config"

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

export QEMU_LD_PREFIX="`readlink -m "$ROOTDIR"`"
export FAKECHROOT_CMD_SUBST=/usr/bin/ldd=/usr/bin/ldd.fakechroot:/sbin/ldconfig=/bin/true

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

# create multistrap.conf
echo "I: create multistrap.conf"
MULTISTRAPCONF=`tempfile -d . -p multistrap`
echo -n > "$MULTISTRAPCONF"
while read line; do
	eval echo $line >> "$MULTISTRAPCONF"
done < $BOARD/multistrap.conf

# download and extract packages
echo "I: run multistrap" >&2
multistrap $MSTRAP_SIM -f "$MULTISTRAPCONF"
[ -z "$MSTRAP_SIM" ] || exit 0

rm -f "$MULTISTRAPCONF"

# convert absolute symlinks for fakechroot
for link in `find $ROOTDIR -type l`; do
        target=`readlink $link`
        if [ "${target%%/*}" = "" ]; then # target begins with slash
		echo "I: convert symlink: ${link#$ROOTDIR} -> $target"
		rm $link
                ln -s ${ROOTDIR}$target $link
        fi
done

# copy initial directory tree - dereference symlinks
echo "I: copy initial directory root tree $BOARD/root/ to $ROOTDIR/"
if [ -r "$BOARD/root" ]; then
	cp --recursive --dereference $BOARD/root/* $ROOTDIR/
fi

# preseed debconf
echo "I: preseed debconf"
if [ -r "$BOARD/debconfseed.txt" ]; then
	cp "$BOARD/debconfseed.txt" $ROOTDIR/tmp/
	fakechroot chroot $ROOTDIR debconf-set-selections /tmp/debconfseed.txt
	rm $ROOTDIR/tmp/debconfseed.txt
fi

# run preinst scripts
for script in $ROOTDIR/var/lib/dpkg/info/*.preinst; do
	[ "$script" = "$ROOTDIR/var/lib/dpkg/info/vpnc.preinst" ] && continue
	echo "I: run preinst script ${script##$ROOTDIR}"
	DPKG_MAINTSCRIPT_NAME=preinst \
	DPKG_MAINTSCRIPT_PACKAGE="`basename $script .preinst`" \
	fakechroot chroot $ROOTDIR ${script##$ROOTDIR} install
done

# run dpkg --configure -a twice because of errors during the first run
echo "I: configure packages"
fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a || fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a

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
# tar is clever enough to not try and put the archive inside itself
TARBALL=$(basename $ROOTDIR).tar
echo "I: create tarball $TARBALL"
fakechroot chroot $ROOTDIR tar -cf $TARBALL -C / .
mv $ROOTDIR/$TARBALL .
