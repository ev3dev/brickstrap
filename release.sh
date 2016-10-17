#!/bin/bash
#
# Maintainer script for publishing releases.

set -e

source=$(dpkg-parsechangelog -S Source)
version=$(dpkg-parsechangelog -S Version)

OS=ubuntu DIST=trusty ARCH=amd64 pbuilder-ev3dev build
debsign ~/pbuilder-ev3dev/ubuntu/trusty-amd64/${source}_${version}_amd64.changes
dput ev3dev-ubuntu ~/pbuilder-ev3dev/ubuntu/trusty-amd64/${source}_${version}_amd64.changes

gbp buildpackage --git-tag-only

ssh ev3dev@reprepro.ev3dev.org "reprepro -b ~/reprepro/ubuntu includedsc xenial \
    ~/reprepro/ubuntu/pool/main/${source:0:1}/${source}/${source}_${version}.dsc"
ssh ev3dev@reprepro.ev3dev.org "reprepro -b ~/reprepro/ubuntu includedeb xenial \
    ~/reprepro/ubuntu/pool/main/${source:0:1}/${source}/brickstrap_${version}_all.deb"
