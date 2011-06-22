#!/bin/sh -ex

dir_depth() {
	dir="$1"
	while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
		dir=`dirname "$dir"`
		echo -n ../
	done
}

if [ "$#" -ne 1 ]; then
	echo "you have to specify the new target name"
	exit
fi

PLATFORM="$1"

if [ -e "$PLATFORM" ]; then
	echo "target already exists"
	exit
fi

mkdir -p $PLATFORM/
mkdir -p $PLATFORM/packages/
mkdir -p $PLATFORM/root/etc/network/
mkdir -p $PLATFORM/hooks/

cp default/config $PLATFORM
cp default/multistrap.conf $PLATFORM
cp default/debconfseed.txt $PLATFORM

for f in packages/base \
         root/usr/sbin/policy-rc.d \
         root/usr/bin/ldd \
         root/etc/apt/apt.conf.d/99no-install-recommends \
         root/etc/apt/apt.conf.d/99no-pdiffs \
         root/etc/ld.so.conf \
         root/etc/ssh/ssh_host_ecdsa_key \
         root/etc/ssh/ssh_host_rsa_key \
         root/etc/ssh/ssh_host_dsa_key \
         root/sbin/ldconfig \
         hooks/create_user \
         hooks/serial_tty \
         hooks/firstboot \
         hooks/empty_password; do
	mkdir -p `dirname $PLATFORM/$f`
	ln -s `dir_depth $f`default/$f $PLATFORM/$f
done

cat << __END__ > $PLATFORM/root/etc/hosts
127.0.0.1 localhost
127.0.0.1 $PLATFORM
__END__

echo $PLATFORM > $PLATFORM/root/etc/hostname

cp default/root/etc/fstab $PLATFORM/root/etc/
cp default/root/etc/network/interfaces $PLATFORM/root/etc/network/
