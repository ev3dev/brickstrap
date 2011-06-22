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

set -ex

usage() {
	echo "Usage: $0: [-s suite] [-a arch] [-d directory] [-m mirror] [-p packages] platform\n"
}

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true LC_ALL=C LANGUAGE=C LANG=C

if [ "$FAKEROOTKEY" = "" ]; then
        echo "re-executing script inside fakeroot"
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

[ "$#" -ne 1 ] && { echo "too many positional arguments"; usage; exit; }

PLATFORM="$1"

[ ! -r "$PLATFORM" ] && { echo "cannot find target directory: $PLATFORM"; exit; }
[ ! -r "$PLATFORM/multistrap.conf" ] && { echo "cannot read multistrap config: $PLATFORM/multistrap.conf"; exit; }

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

echo "--------------------------"
echo "suite:   $SUITE"
echo "arch:    $ARCH"
echo "rootdir: $ROOTDIR"
echo "mirror:  $MIRROR"
echo "pkgs:    $PACKAGES"
echo "--------------------------"

[ -e "$ROOTDIR.tar" ] && { echo "tarball still exists"; exit; }
[ -e "$ROOTDIR" ] && { echo "root directory still exists"; exit; }

# create multistrap.conf
echo -n > /tmp/multistrap.conf
while read line; do
        eval echo $line >> /tmp/multistrap.conf
done < $PLATFORM/multistrap.conf

# download and extract packages
multistrap -f /tmp/multistrap.conf

# backup ldconfig and ldd
mv $ROOTDIR/sbin/ldconfig $ROOTDIR/sbin/ldconfig.REAL
mv $ROOTDIR/usr/bin/ldd $ROOTDIR/usr/bin/ldd.REAL

# copy initial directory tree - dereference symlinks
if [ -r "$PLATFORM/root" ]; then
	cp --recursive --dereference $PLATFORM/root/* $ROOTDIR/
fi

# copy qemu usermode binary
if [ $ARCH != "`dpkg --print-architecture`" ]; then
	case $ARCH in
		alpha|arm|armeb|i386|m68k|mips|mipsel|ppc64|sh4|sh4eb|sparc|sparc64)
		cp `which qemu-$ARCH-static` $ROOTDIR/usr/bin;;
		amd64) cp `which qemu-x86_64-static` $ROOTDIR/usr/bin;;
		armel) cp `which qemu-arm-static` $ROOTDIR/usr/bin;;
		lpia) cp `which qemu-i386-static` $ROOTDIR/usr/bin;;
		powerpc) cp `which qemu-ppc-static` $ROOTDIR/usr/bin;;
		*) echo "unknown architecture: $ARCH"; exit 1;;
	esac
fi

# preseed debconf
if [ -r "$PLATFORM/debconfseed.txt" ]; then
	cp "$PLATFORM/debconfseed.txt" $ROOTDIR/tmp/
	fakechroot chroot $ROOTDIR debconf-set-selections /tmp/debconfseed.txt
	rm $ROOTDIR/tmp/debconfseed.txt
fi

# run preinst scripts
for script in $ROOTDIR/var/lib/dpkg/info/*.preinst; do
        [ "$script" = "$ROOTDIR/var/lib/dpkg/info/bash.preinst" ] && continue
        fakechroot chroot $ROOTDIR ${script##$ROOTDIR} install
done

# run dpkg --configure -a twice because of errors during the first run
fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a || fakechroot chroot $ROOTDIR /usr/bin/dpkg --configure -a

# source hooks
if [ -r "$PLATFORM/hooks" ]; then
	for f in $PLATFORM/hooks/*; do
		. $f
	done
fi

#cleanup
rm $ROOTDIR/sbin/ldconfig $ROOTDIR/usr/bin/ldd
mv $ROOTDIR/sbin/ldconfig.REAL $ROOTDIR/sbin/ldconfig
mv $ROOTDIR/usr/bin/ldd.REAL $ROOTDIR/usr/bin/ldd
rm $ROOTDIR/usr/sbin/policy-rc.d

# need to generate tar inside fakechroot so that absolute symlinks are correct
# tar is clever enough to not try and put the archive inside itself
fakechroot chroot $ROOTDIR tar -cf $ROOTDIR.tar -C / .
mv $ROOTDIR/$ROOTDIR.tar .
