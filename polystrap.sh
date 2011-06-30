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

set -e

usage() {
	echo "Usage: $0: [-s suite] [-a arch] [-d directory] [-m mirror] [-p packages] platform\n" >&2
}

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C
export PATH=$PATH:/usr/sbin:/sbin

if [ "$FAKEROOTKEY" = "" ]; then
	echo "I: re-executing script inside fakeroot" >&2
	fakeroot "$0" "$@";
	exit
fi

while getopts s:a:d:m:p: opt; do
	case $opt in
	s) _SUITE="$OPTARG";;
	a) _ARCH="$OPTARG";;
	d) _ROOTDIR="$OPTARG";;
	m) _MIRROR="$OPTARG";;
	p) _PACKAGES="$OPTARG";;
	?) usage; exit 1;;
	esac
done
shift $(($OPTIND - 1))

[ "$#" -ne 1 ] && { echo "too many positional arguments" >&2; usage; exit 1; }

PLATFORM="$1"

[ ! -r "$PLATFORM" ] && { echo "cannot find target directory: $PLATFORM" >&2; exit 1; }
[ ! -r "$PLATFORM/multistrap.conf" ] && { echo "cannot read multistrap config: $PLATFORM/multistrap.conf" >&2; exit 1; }

# source default options
. "default/config"

# overwrite default options by target options
[ -r "$PLATFORM/config" ] && . "$PLATFORM/config"

# overwrite target options by commandline options
SUITE=${_SUITE:-$SUITE}
ARCH=${_ARCH:-$ARCH}
ROOTDIR=${_ROOTDIR:-$ROOTDIR}
MIRROR=${_MIRROR:-$MIRROR}

if [ "$_PACKAGES" = "" ] && [ -r "$PLATFORM/packages" ]; then
	# if no packages were given by commandline, read from package files
	for f in $PLATFORM/packages/*; do
		while read line; do PACKAGES="$PACKAGES $line"; done < "$f"
	done
else
	# otherwise set as given by commandline
	PACKAGES="$_PACKAGES"
fi

# binutils must always be installed for objdump for fake ldd
PACKAGES="$PACKAGES binutils"

echo "I: --------------------------" >&2
echo "I: suite:   $SUITE"            >&2
echo "I: arch:    $ARCH"             >&2
echo "I: rootdir: $ROOTDIR"          >&2
echo "I: mirror:  $MIRROR"           >&2
echo "I: pkgs:    $PACKAGES"         >&2
echo "I: --------------------------" >&2

[ -e "$ROOTDIR.tar" ] && { echo "tarball still exists" >&2; exit 1; }
[ -e "$ROOTDIR" ] && { echo "root directory still exists" >&2; exit 1; }

# create multistrap.conf
echo "I: create multistrap.conf" >&2
MULTISTRAPCONF=`tempfile -d . -p multistrap`
echo -n > "$MULTISTRAPCONF"
while read line; do
	eval echo $line >> "$MULTISTRAPCONF"
done < $PLATFORM/multistrap.conf

# download and extract packages
echo "I: run multistrap" >&2
multistrap -f "$MULTISTRAPCONF"
rm -f "$MULTISTRAPCONF"

# backup ldconfig and ldd
echo "I: backup ldconfig and ldd" >&2
mv $ROOTDIR/sbin/ldconfig $ROOTDIR/sbin/ldconfig.REAL
mv $ROOTDIR/usr/bin/ldd $ROOTDIR/usr/bin/ldd.REAL

# copy initial directory tree - dereference symlinks
echo "I: copy initial directory root tree $PLATFORM/root/ to $ROOTDIR/" >&2
if [ -r "$PLATFORM/root" ]; then
	cp --recursive --dereference $PLATFORM/root/* $ROOTDIR/
fi

# copy qemu usermode binary
QEMUARCH=
if [ $ARCH != "`dpkg --print-architecture`" ]; then
	case $ARCH in
		alpha|i386|m68k|mips|mipsel|ppc64|sh4|sh4eb|sparc|sparc64)
		         QEMUARCH=$ARCH;;
		arm*)    QEMUARCH=arm;; # for arm, armel, armeb, armhf
		amd64)   QEMUARCH=x86_64;;
		lpia)    QEMUARCH=i386;;
		powerpc) QEMUARCH=ppc;;
		*) echo "unknown architecture: $ARCH" >&2; exit 1;;
	esac
fi
echo "I: copy qemu-$QEMUARCH-static into $ROOTDIR" >&2
cp `which qemu-$QEMUARCH-static` $ROOTDIR/usr/bin

# preseed debconf
echo "I: preseed debconf" >&2
if [ -r "$PLATFORM/debconfseed.txt" ]; then
	cp "$PLATFORM/debconfseed.txt" $ROOTDIR/tmp/
	fakechroot chroot $ROOTDIR debconf-set-selections /tmp/debconfseed.txt
	rm $ROOTDIR/tmp/debconfseed.txt
fi

# run preinst scripts
for script in $ROOTDIR/var/lib/dpkg/info/*.preinst; do
	[ "$script" = "$ROOTDIR/var/lib/dpkg/info/bash.preinst" ] && continue
	echo "I: run preinst script ${script##$ROOTDIR}" >&2
	fakechroot chroot $ROOTDIR ${script##$ROOTDIR} install
done

# run dpkg --configure -a twice because of errors during the first run
echo "I: configure packages" >&2
fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a || fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a

# source hooks
if [ -r "$PLATFORM/hooks" ]; then
	for f in $PLATFORM/hooks/*; do
		echo "I: run hook $f" >&2
		. $f
	done
fi

#cleanup
echo "I: cleanup" >&2
rm $ROOTDIR/sbin/ldconfig $ROOTDIR/usr/bin/ldd
mv $ROOTDIR/sbin/ldconfig.REAL $ROOTDIR/sbin/ldconfig
mv $ROOTDIR/usr/bin/ldd.REAL $ROOTDIR/usr/bin/ldd
rm $ROOTDIR/usr/sbin/policy-rc.d

# need to generate tar inside fakechroot so that absolute symlinks are correct
# tar is clever enough to not try and put the archive inside itself
echo "I: create tarball $ROOTDIR.tar" >&2
fakechroot chroot $ROOTDIR tar -cf $ROOTDIR.tar -C / .
mv $ROOTDIR/$ROOTDIR.tar .
