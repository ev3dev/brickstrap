#!/bin/bash
#
# brickstrap - create a foreign architecture rootfs using multistrap, proot,
#              and qemu usermode emulation and disk image using libguestfs
#
# Copyright (C) 2014 David Lechner <david@lechnology.com>
# Copyright (C) 2014 Ralph Hempel <rhempel@hempeldesigngroup.com>
#
# Based on polystrap:
# Copyright (C) 2011 by Johannes 'josch' Schauer <j.schauer@email.de>
#
# Template to write better bash scripts.
# More info: http://kvz.io/blog/2013/02/26/introducing-bash3boilerplate/
# Version 0.0.1
#
# Licensed under MIT
# Copyright (c) 2013 Kevin van Zonneveld
# http://twitter.com/kvz
#

### Configuration
#####################################################################

# Environment variables
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="3" # 4 = debug -> 0 = fail

# Commandline options. This defines the usage page

read -r -d '' usage <<-'EOF'
  usage: brickstrap [-b <board>] [-d <dir>] <command>

Options
-------
-b <board> Directory that contains board definition. (Default: ev3dev-jessie)
-d <dir>   The name of the directory for the rootfs. Note: This is also
           used for the .tar and .img file names.
-f         Force overwriting existing files/directories.
-h         Help. (You are looking at it.)

  Commands
  --------
  create-conf          generates multistrap.conf
* simulate-multistrap  runs multistrap with the --simulate option (for debuging)
  run-multistrap       runs multistrap (creates rootfs and downloads packages)
  copy-root            copies files from board definition folder to the rootfs
  configure-packages   configures the packages in the rootfs
  run-hooks            runs the hooks in the board configuration folder
  create-tar           creates a tar file from the rootfs folder
  create-image         creates a disk image file from the tar file

* shell                runs a bash shell in the rootfs using qemu
  all                  runs all of the above commands (except *) in order

  Environment Variables
  ---------------------
  LOG_LEVEL     Specifies log level verbosity (0-4)
                0=fail, ... 3=info(default), 4=debug

  DEBIAN_MIRROR Specifies the debian mirror used by apt
                default: http://ftp.debian.org/debian
                (applies to create-conf only)

  EV3DEV_MIRROR Specifies the ev3dev mirror used by apt
                default: http://ev3dev.org/debian
                (applies to create-conf only)
EOF

### Functions
#####################################################################


function _fmt () {
  color_info="\x1b[32m"
  color_warn="\x1b[33m"
  color_error="\x1b[31m"

  color=
  [ "${1}" = "info" ] && color="${color_info}"
  [ "${1}" = "warn" ] && color="${color_warn}"
  [ "${1}" = "error" ] && color="${color_error}"
  [ "${1}" = "fail" ] && color="${color_error}"

  color_reset="\x1b[0m"
  if [ "${TERM}" != "xterm" ] || [ -t 1 ]; then
    # Don't use colors on pipes on non-recognized terminals
    color=""
    color_reset=""
  fi
  echo -e "$(date +"%H:%M:%S") [${color}$(printf "%5s" ${1})${color_reset}]";
}

function fail ()  {                             echo "$(_fmt fail) ${@}"  || true; exit 1; }
function error () { [ "${LOG_LEVEL}" -ge 1 ] && echo "$(_fmt error) ${@}" || true;         }
function warn ()  { [ "${LOG_LEVEL}" -ge 2 ] && echo "$(_fmt warn) ${@}"  || true;         }
function info ()  { [ "${LOG_LEVEL}" -ge 3 ] && echo "$(_fmt info) ${@}"  || true;         }
function debug () { [ "${LOG_LEVEL}" -ge 4 ] && echo "$(_fmt debug) ${@}" || true;         }

function help() {
    echo >&2 "${@}"
    echo >&2 "  ${usage}"
    echo >&2 ""
}

### Parse commandline options - adding the while loop around the
### getopts loop allows commands anywhere in the command line.
###
### Note that cmd gets set to the first non-option string, others
### are simply ignored
#####################################################################

BOARD="ev3dev-jessie"

while [ $# -gt 0 ] ; do
    while getopts "fb:d:" opt; do
        case "$opt" in
           f) FORCE=true;;
           b) BOARD="$OPTARG";;
           d) _ROOTDIR="$OPTARG";;
          \?) # unknown flag
                help
                exit 1
            ;;
        esac
    done

    shift $((OPTIND-1))

    cmd=${cmd:=$1}

    shift 1
    OPTIND=1
done

[ "${cmd}" = "" ] && help && exit 1
debug "cmd: ${cmd}"

#####################################################################
### Set up the variables for the commands

SCRIPT_PATH=$(dirname $(readlink -f "$0"))

debug "SCRIPT_PATH: ${SCRIPT_PATH}"

CHROOTQEMUCMD="proot -q qemu-arm -v -1 -0"
CHROOTQEMUBINDCMD=${CHROOTQEMUCMD}" -b /dev -b /sys -b /proc"
CHROOTCMD="proot -v -1 -0"

export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    LC_ALL=C LANGUAGE=C LANG=C
export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

[ -r "${BOARD}" ] || BOARD="${SCRIPT_PATH}/${BOARD}"
[ -r "${BOARD}" ] || fail "cannot find target directory: ${BOARD}"
[ -r "${BOARD}/multistrap.conf" ] \
    || fail "cannot read multistrap config: ${BOARD}/multistrap.conf"

SYSTEM_KERNEL_IMAGE="/boot/vmlinuz-$(uname -r)"
[ -r "${SYSTEM_KERNEL_IMAGE}" ] \
    || fail "Cannot read ${SYSTEM_KERNEL_IMAGE} needed by guestfish." \
    "Set permission with 'sudo chmod +r ${SYSTEM_KERNEL_IMAGE}'."

# source default options
. "${SCRIPT_PATH}/default/config"

# overwrite default options by target options
[ -r "${BOARD}/config" ] && . "${BOARD}/config"

# overwrite target options by commandline options
MULTISTRAPCONF="multistrap.conf"
ROOTDIR=$(readlink -m ${_ROOTDIR:-$ROOTDIR})
TARBALL=$(pwd)/$(basename ${ROOTDIR}).tar
IMAGE=$(pwd)/$(basename ${ROOTDIR}).img

### Runtime
#####################################################################

set -e

# Bash will remember & return the highest exitcode in a chain of pipes.
# This way you can catch the error in case mysqldump fails in `mysqldump |gzip`
set -o pipefail

#####################################################################

function create-conf() {
    info "Creating multistrap configuration file..."
    debug "BOARD: ${BOARD}"
    for f in ${BOARD}/packages/*; do
        while read line; do PACKAGES="${PACKAGES} $line"; done < "$f"
    done

    multistrapconf_aptpreferences=false
    multistrapconf_cleanup=false;

    debug "creating ${MULTISTRAPCONF}"
    echo -n > "${MULTISTRAPCONF}"
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
}

function simulate-multistrap() {
    MSTRAP_SIM="--simulate"
    run-multistrap
}

function run-multistrap() {
    info "running multistrap..."
    [ -z ${FORCE} ] && [ -d "${ROOTDIR}" ] && \
        fail "${ROOTDIR} already exists. Use -f option to overwrite."
    debug "MULTISTRAPCONF: ${MULTISTRAPCONF}"
    debug "ROOTDIR: ${ROOTDIR}"
    if [ ! -z ${FORCE} ] && [ -d "${ROOTDIR}" ]; then
        warn "Removing existing rootfs ${ROOTDIR}"
        rm -rf ${ROOTDIR}
    fi
    proot -0 multistrap ${MSTRAP_SIM} --file "${MULTISTRAPCONF}" --no-auth
}

function copy-root() {
    info "Copying root files from board definition..."
    debug "BOARD: ${BOARD}"
    debug "ROOTDIR: ${ROOTDIR}"
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    # copy initial directory tree - dereference symlinks
    if [ -r "${BOARD}/root" ]; then
        cp --recursive --dereference "${BOARD}/root/"* "${ROOTDIR}/"
    fi
}

function configure-packages () {
    info "Configuring packages..."
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."

    # preseed debconf
    info "preseed debconf"
    if [ -r "${BOARD}/debconfseed.txt" ]; then
        cp "${BOARD}/debconfseed.txt" "${ROOTDIR}/tmp/"
        ${CHROOTQEMUCMD} -r ${ROOTDIR} debconf-set-selections /tmp/debconfseed.txt
        rm "${ROOTDIR}/tmp/debconfseed.txt"
    fi

    # run preinst scripts
    info "running preinst scripts..."
    script_dir="${ROOTDIR}/var/lib/dpkg/info"
    for script in ${script_dir}/*.preinst; do
        blacklisted="false"
        if [ -r "${BOARD}/preinst.blacklist" ]; then
            while read line; do
                if [ "${script##$script_dir}" = "/${line}.preinst" ]; then
                    blacklisted="true"
                    info "skipping ${script##$script_dir} (blacklisted)"
                    break
                fi
            done < "${BOARD}/preinst.blacklist"
        fi
        [ "${blacklisted}" = "true" ] && continue
        info "running ${script##$script_dir}"
        DPKG_MAINTSCRIPT_NAME=preinst \
        DPKG_MAINTSCRIPT_PACKAGE="`basename ${script} .preinst`" \
            ${CHROOTQEMUBINDCMD} -r ${ROOTDIR} ${script##$ROOTDIR} install
    done

    # run dpkg `--configure -a` twice because of errors during the first run
    info "configuring packages..."
    ${CHROOTQEMUBINDCMD} -r ${ROOTDIR} /usr/bin/dpkg --configure -a || \
    ${CHROOTQEMUBINDCMD} -r ${ROOTDIR} /usr/bin/dpkg --configure -a || true
}

function run-hooks() {
    info "Running hooks..."
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."

    # source hooks
    if [ -r "${BOARD}/hooks" ]; then
        for f in "${BOARD}"/hooks/*; do
            info "running hook ${f##${BOARD}/hooks/}"
            . ${f}
        done
    fi
}

function create-tar() {
    info "Creating tar of rootfs"
    debug "ROOTDIR: ${ROOTDIR}"
    debug "TARBALL: ${TARBALL}"
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    [ -z ${FORCE} ] && [ -f "${TARBALL}" ] \
	    && fail "${TARBALL} exists. Use -f option to overwrite."
    # need to generate tar inside fakechroot so that absolute symlinks are correct
    info "creating tarball ${TARBALL}"
    info "Excluding files:
$(${CHROOTQEMUCMD} -r ${ROOTDIR} cat host-rootfs${BOARD}/tar-exclude)"
    ${CHROOTQEMUCMD} -r ${ROOTDIR} tar -cpf host-rootfs/${TARBALL} \
        --exclude=host-rootfs --exclude-from=host-rootfs${BOARD}/tar-exclude /
}


function create-image() {
    info "Creating image file..."
    debug "TARBALL: ${TARBALL}"
    debug "IMAGE: ${IMAGE}"
    debug "IMAGE_FILE_SIZE: ${IMAGE_FILE_SIZE}"
    [ ! -f ${TARBALL} ] && fail "Could not find ${TARBALL}"
    [ -z ${FORCE} ] && [ -f ${IMAGE} ] && \
        fail "${IMAGE} already exists. Use -f option to overwrite."

    guestfish -N bootrootlv:/dev/ev3devVG/root:vfat:ext3:${IMAGE_FILE_SIZE}:32M:mbr \
         part-set-mbr-id /dev/sda 1 0x0b : \
         set-label /dev/ev3devVG/root EV3_FILESYS : \
         mount /dev/ev3devVG/root / : \
         tar-in ${TARBALL} / : \
         mkdir-p /media/mmc_p1 : \
         mount /dev/sda1 /media/mmc_p1 : \
         mv /uImage /media/mmc_p1/ : \
         mv /uInitrd /media/mmc_p1/ : \
         mv /boot.scr /media/mmc_p1/ : \

    # Hack to set the volume label on the vfat partition since guestfish does
    # not know how to do that. Must be null padded to exactly 11 bytes.
    echo -e -n "EV3_BOOT\0\0\0" | \
	    dd of=test1.img bs=1 seek=32811 count=11 conv=notrunc >/dev/null 2>&1

    mv test1.img ${IMAGE}
}

function run-shell() {
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    HOME=/root ${CHROOTQEMUBINDCMD} -r ${ROOTDIR} bash
}

case "${cmd}" in
    create-conf)         create-conf;;
    simulate-multistrap) simulate-multistrap;;
    run-multistrap)      run-multistrap;;
    copy-root)           copy-root;;
    configure-packages)  configure-packages;;
    run-hooks)           run-hooks;;
    create-tar)          create-tar;;
    create-image)        create-image;;

    shell) run-shell;;

    all) create-conf
         run-multistrap
         copy-root
         configure-packages
         run-hooks
         create-tar
         create-image
    ;;

    *) fail "Unknown command. See brickstrap -h for list of commands.";;
esac
