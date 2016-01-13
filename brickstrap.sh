#!/bin/bash
#
# brickstrap - create a foreign architecture rootfs using kernel namespaces,
#              multistrap, and qemu usermode emulation and create a disk image
#              using libguestfs
#
# Copyright (C) 2016      Johan Ouwerkerk <jm.ouwerkerk@gmail.com>
# Copyright (C) 2014-2015 David Lechner <david@lechnology.com>
# Copyright (C) 2014-2015 Ralph Hempel <rhempel@hempeldesigngroup.com>
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

### Runtime
#####################################################################
set -e

# Bash will remember & return the highest exitcode in a chain of pipes.
set -o pipefail

# Environment variables
[ -z "${LOG_LEVEL}" ] && LOG_LEVEL="3" # 4 = debug -> 0 = fail

#
# Get the brickstrap source directory
#
function br_script_path()
{
    SCRIPT_PATH=$(readlink -f "$0")
    SCRIPT_PATH=$(dirname "$SCRIPT_PATH")
    echo -n "$SCRIPT_PATH"
}

. "$(br_script_path)/brickstrap-components.sh"
. "$(br_script_path)/brickstrap-utils.sh"

# Commandline options. This defines the usage page
BRP_USAGE=$(cat <<'EOF'
Usage: brickstrap -p <project> [-c <component>] [-d <dir>] <command>

Options
-------
-c <component> Select components from the project directory.
               Multiple components may be selected by specifying multiple '-c'
               options; at least one component must be specified.
-d <dir>       The name of the directory for the rootfs.
               Note: This is also used for the .tar and .img file names.
-p <project>   Directory which contains the brickstrap configuration (project).
               This option is required and should occur exactly once.
               Values are either a path to the project directory or the name of
               an example project shipped with brickstrap by default.
-Q <qemu>      Optional: override which QEMU binary to use for emulation of
               foreign instruction sets.

               The <qemu> value must be either the path to a binary or
               the name of a Debian or QEMU architecture or the special string
               'none'. If <qemu> corresponds to a binary it is used
               unconditionally, without further validation. If <qemu> is an
               architecture which matches the host architecture or 'native'
               then no emulator will be used. Otherwise the system is queried
               for a well known QEMU emulator for the architecture matching the
               <qemu> value.
-f             Force overwriting existing files/directories.
-h             Help. (You are looking at it.)

  Commands
  --------
  create-conf          generate the multistrap.conf file
* simulate-multistrap  debug/dry-run of multistrap using its --simulate option
  run-multistrap       run multistrap (creates rootfs and downloads packages)
  copy-root            copy files from project definition folder to the rootfs
  configure-packages   configure the packages in the rootfs
* run-hook <hook>      run a single hook in the project configuration folder
  run-hooks            run all of the hooks in the project configuration folder
* create-rootfs        run all of the above commands (except *) in order
  create-tar           create a tar file from the rootfs folder
  create-image         create a disk image file from the tar file
  create-report        run custom reporting script <project>/custom-report.sh
* shell [shell]        run the given shell in the rootfs (default is bash).
* delete               deletes all of the files created by other commands
  all                  run all of the above commands (except *) in order

  Environment Variables
  ---------------------
  LOG_LEVEL               Specifies log level verbosity (0-4)
                          0=fail, ... 3=info(default), 4=debug

  DEBIAN_MIRROR           Specifies the debian mirror used by apt
                          default: http://httpredir.debian.org/debian
                          (applies to create-conf only)

  RASPBIAN_MIRROR         Specifies the Raspbian mirror used by apt
                          default: http://archive.raspbian.org/raspbian
                          (applies to create-conf only)

  EV3DEV_MIRROR           Specifies the ev3dev mirror used by apt
                          default: http://ev3dev.org/debian
                          (applies to create-conf only)

  EV3DEV_RASPBIAN_MIRROR  Specifies the ev3dev/raspbian mirror used by apt
                          default: http://ev3dev.org/raspbian
                          (applies to create-conf only)

EOF
);

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
    # Don't use colours when using pipes in unrecognised terminals
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

function brp_help() {
    if [ $# -ge 1 ]; then
        echo >&2 "${@}"
    fi
    echo >&2 "${BRP_USAGE}"
    echo >&2 ""
}

### Parse commandline options - adding the while loop around the
### getopts loop allows commands anywhere in the command line.
###
### Note that cmd gets set to the first non-option string, others
### are simply ignored
#####################################################################

function brp_parse_cli_options()
{
    while [ $# -gt 0 ] ; do
        while getopts "fhc:d:p:Q:" BRP_OPT; do
            case "$BRP_OPT" in
            f) FORCE=true;;
            h)
                brp_help
                exit 0
            ;;
            p)
                if [ -z "$OPTARG" ]; then
                    brp_help 'Empty project names are invalid'
                    exit 1
                elif [ -z "$BR_PROJECT" ]; then
                    BR_PROJECT="$OPTARG"
                elif [ "$BR_PROJECT" = "$OPTARG" ]; then
                    warn "Ignoring duplicate project: '$OPTARG'"
                else
                    brp_help "Duplicate project: -$BRP_OPT '$OPTARG'.
Project was: '$BR_PROJECT'"
                    exit 1
                fi
            ;;
            c)
                if [ -z "$OPTARG" ]; then
                    brp_help 'Empty component names are invalid'
                    exit 1
                elif [ -z "$BR_COMPONENTS" ]; then
                    BR_COMPONENTS="'$OPTARG'"
                elif echo "$BR_COMPONENTS" | fgrep -q "'$OPTARG'"; then
                    warn "Ignoring duplicate component: -$BRP_OPT '$OPTARG'"
                else
                    BR_COMPONENTS="$BR_COMPONENTS '$OPTARG'"
                fi
            ;;
            d) ROOTDIR="$OPTARG";;
            Q)
                if [ -z "$OPTARG" ]; then
                    brp_help 'Empty QEMU architecture names are invalid.'
                    exit 1
                elif [ -z "$BR_QEMU" ]; then
                    BR_QEMU="$OPTARG"
                elif [ "$BR_QEMU" = "$OPTARG" ]; then
                    warn "Ignoring duplicate QEMU architecture: '$OPTARG'"
                else
                    brp_help "Duplicate QEMU architecture: -$BRP_OPT '$OPTARG'.
QEMU architecture was: '$BR_QEMU'"
                    exit 1
                fi
            ;;
            \?) # unknown flag or missing argument
                brp_help
                exit 1
            ;;
            esac
        done

        shift $((OPTIND-1))

        if [ "$BRP_CMD" == "run-hook" ] || [ "$BRP_CMD" == "shell" ]; then
            BRP_CMD_ARG="$1"
        fi

        BRP_CMD="${BRP_CMD:=$1}"

        shift 1
        OPTIND=1
    done
}

function brp_sanity_check_cli_options()
{
    if [ $# -eq 0 -o -z "$1" ]; then
        brp_help 'No command specified'
        exit 1
    elif [ "$1" = "run-hook" ] && [ $# -eq 1 -o -z "$2" ]; then
        brp_help 'No hook specified'
        exit 1
    fi
    debug "cmd: $1"
}

function brp_validate_cli_options()
{
    brp_sanity_check_cli_options "$@"
    brp_validate_project_name
    brp_validate_component_names
    brp_validate_qemu || [ $? -eq 255 ] # no QEMU specified = 255
}


#####################################################################
### Set up the variables for the commands

function brp_init_env()
{

    debug "SCRIPT_PATH: $(br_script_path)"

    export DEBIAN_FRONTEND=noninteractive
    export DEBCONF_NONINTERACTIVE_SEEN=true
    export LC_ALL=C LANGUAGE=C LANG=C
    export PATH=$PATH:/usr/local/sbin:/usr/sbin:/sbin

    br_list_paths "multistrap.conf" -r >/dev/null || \
        fail "Unable to locate a readable 'multistrap.conf'"

    for SYSTEM_KERNEL_IMAGE in /boot/vmlinuz-*; do
        [ -r "${SYSTEM_KERNEL_IMAGE}" ] \
            || fail "Cannot read ${SYSTEM_KERNEL_IMAGE} needed by guestfish." \
            "Set permission with 'sudo chmod +r /boot/vmlinuz-*'."
    done

    if [ "$(sysctl -ne kernel.unprivileged_userns_clone)" = "0" ]; then
        fail "Unprivileged user namespace clone is disabled. Enable it by running" \
            "'sudo sysctl -w kernel.unprivileged_userns_clone=1'."
    fi

    # source project config file
    if br_list_paths config -r >/dev/null; then
        br_for_each_path "$(br_list_paths config -r)" brp_run_hook_impl \
            'loading'
    fi

    # overwrite target options by commandline options
    DEFAULT_ROOTDIR=$(readlink -f "$(basename "$BR_PROJECT")-$(date +%F)")
    ROOTDIR=$(readlink -m ${ROOTDIR:-$DEFAULT_ROOTDIR})
    MULTISTRAPCONF=$(pwd)/$(basename ${ROOTDIR}).multistrap.conf
    TARBALL=$(pwd)/$(basename ${ROOTDIR}).tar
    IMAGE=$(pwd)/$(basename ${ROOTDIR}).img
}

function brp_read_package_file()
{
    # check that the package file hasn't been blacklisted
    if echo "$BLACKLIST_PACKAGE_FILES" | fgrep -q "$(basename "$1")"; then
        return 0
    fi
    while IFS='' read -r BRP_CUR_LINE || [ -n "$BRP_CUR_LINE" ]; do
        case "$BRP_CUR_LINE" in
        \#*|\;*) # permit comments: lines starting with # or ; are ignored.
        ;;
        *)
            # avoid redundant spaces, i.e.  empty lines are ignored.
            # also check that the package line hasn't been blacklisted
            if [ -z "$BRP_CUR_LINE" ] || \
                echo "$BLACKLIST_PACKAGES" | fgrep -q "$BRP_CUR_LINE"; then
                continue
            else
                PACKAGES="${PACKAGES} $BRP_CUR_LINE"
            fi
        ;;
        esac
    done < "$1"
}

function brp_read_multistrap_conf_file()
{
    while read BRP_CUR_LINE; do
        eval echo "$BRP_CUR_LINE" >> "$MULTISTRAPCONF"
        if echo "$BRP_CUR_LINE" | egrep -q "^aptpreferences="
        then
                multistrapconf_aptpreferences=true
        fi
        if echo "$BRP_CUR_LINE" | egrep -q "^cleanup=true"
        then
               multistrapconf_cleanup=true
        fi
    done < "$1"
}

function brp_create_conf() {
    #
    # Set the defaults for mirrors as promised by help, if these have not been
    # configured for the project yet.
    #
    if [ -z "${DEBIAN_MIRROR}" ]; then
        DEBIAN_MIRROR="http://httpredir.debian.org/debian"
    fi
    if [ -z "${RASPBIAN_MIRROR}" ]; then
        RASPBIAN_MIRROR="http://archive.raspbian.org/raspbian"
    fi
    if [ -z "${EV3DEV_MIRROR}" ]; then
        EV3DEV_MIRROR="http://ev3dev.org/debian"
    fi
    if [ -z "${EV3DEV_RASPBIAN_MIRROR}" ]; then
        EV3DEV_RASPBIAN_MIRROR="http://ev3dev.org/raspbian"
    fi
    info "Creating multistrap configuration file..."
    debug "br_project_dir: $(br_project_dir)"

    if br_list_directories packages >/dev/null; then
        br_for_each_path_iterate_directories \
            "$(br_list_directories packages)" brp_read_package_file
    fi

    multistrapconf_aptpreferences=false
    multistrapconf_cleanup=false;

    debug "creating ${MULTISTRAPCONF}"
    echo -n > "${MULTISTRAPCONF}"
    br_for_each_path "$(br_list_paths multistrap.conf -f)" \
        brp_read_multistrap_conf_file
}

function brp_simulate_multistrap() {
    MSTRAP_SIM="--simulate"
    brp_run_multistrap
}

function brp_run_multistrap() {
    info "running multistrap..."
    [ -z ${FORCE} ] && [ -d "${ROOTDIR}" ] && \
        fail "${ROOTDIR} already exists. Use -f option to overwrite."
    debug "MULTISTRAPCONF: ${MULTISTRAPCONF}"
    debug "ROOTDIR: ${ROOTDIR}"
    if [ ! -z ${FORCE} ] && [ -d "${ROOTDIR}" ]; then
        warn "Removing existing rootfs ${ROOTDIR}"
        brp_unshare -- rm -rf ${ROOTDIR}
    fi
    brp_unshare -- multistrap ${MSTRAP_SIM} --file "${MULTISTRAPCONF}" \
        --dir ${ROOTDIR} --no-auth
    brp_setup_qemu_in_rootfs
}

function brp_copy_to_root_dir() {
    cp --recursive --dereference "$1/"* "${ROOTDIR}/"
}

function brp_copy_root() {
    info "Copying root files from project definition..."
    debug "br_project_dir: $(br_project_dir)"
    debug "ROOTDIR: ${ROOTDIR}"
    if [ ! -d "${ROOTDIR}" ]; then
        fail "${ROOTDIR} does not exist."
    elif br_list_directories root >/dev/null; then
        # copy initial directory tree - dereference symlinks
        br_for_each_path "$(br_list_directories root)" brp_copy_to_root_dir
    else
        info "Skipping: no such directory: root"
    fi
}

function brp_preseed_debconf() {
    cp "$1" "${ROOTDIR}/tmp/debconfseed.txt"
    br_chroot debconf-set-selections /tmp/debconfseed.txt
    rm "${ROOTDIR}/tmp/debconfseed.txt"
}

function brp_configure_packages () {
    info "Configuring packages..."
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."

    # awk needs to be in the path, but Debian symlinks are not
    # configured yet, so make a temporary one in /usr/local/bin.
    info "Creating awk temporary symlink"
    br_chroot mkdir -p /usr/local/bin
    br_chroot ln -sf /usr/bin/gawk /usr/local/bin/awk

    # preseed debconf
    if br_list_paths debconfseed.txt -r >/dev/null; then
        info "preseed debconf"
        br_for_each_path "$(br_list_paths debconfseed.txt -r)" \
            brp_preseed_debconf
    fi

    # run preinst scripts
    info "running preinst scripts..."
    BRP_script_dir="${ROOTDIR}/var/lib/dpkg/info"
    BRP_preinst_blacklist="$(br_cat_files preinst.blacklist)"
    for BRP_script in ${BRP_script_dir}/*.preinst; do
        if echo "$BRP_preinst_blacklist" | \
            fgrep -xq "$(basename "$BRP_script" .preinst)"; then
            info "skipping $(basename "$BRP_script") (blacklisted)"
        else
            info "running $(basename "$BRP_script")"
                DPKG_MAINTSCRIPT_NAME=preinst \
                DPKG_MAINTSCRIPT_PACKAGE="`basename ${BRP_script} .preinst`" \
                    br_chroot_bind ${BRP_script##$ROOTDIR} install
        fi
    done

    # run dpkg `--configure -a` twice because of errors during the first run
    info "configuring packages..."
    br_chroot_bind /usr/bin/dpkg --configure -a || \
    br_chroot_bind /usr/bin/dpkg --configure -a || true

    # remove our temporary awk symlink as it is no longer required.
    info "Removing awk temporary symlink"
    br_chroot rm -f /usr/local/bin/awk
}

function brp_report_hooks_exit_code()
{
    if [ $1 -ne 0 ]; then
        error "script failed with exit code $1: '$2'"
        return $1
    else
        info "script completed successfully: '$2'"
    fi
}

function brp_run_hook_impl()
{
    if [ -n "$2" ]; then
        info "$1: $2"
        . "$2"
        brp_report_hooks_exit_code "$?" "$2"
    else
        info "runnning hook: $1"
        . "$1"
        brp_report_hooks_exit_code "$?" "$1"
    fi
}

function brp_run_hook() {
    # completely bogus
    if [ $# -eq 0 -o -z "$1" ]; then
        brp_help "Empty hook names are invalid"
        exit 1
    elif [ ! -d "${ROOTDIR}" ]; then
        fail "${ROOTDIR} does not exist."
    # a simple hook name which may or may not map to multiple hooks
    # given the components selection
    elif [ "$(basename "$1")" = "$1" ] || \
        [ "hooks/$(basename "$1")" = "$1" ]; then
        br_for_each_path "$(br_find_paths "hooks/$(basename "$1")" -f)" \
            brp_run_hook_impl
    # probably a full path to a single hook script,
    # should be executed on its own
    elif br_find_paths "hooks/$(basename "$1")" -f | \
            fgrep -xq "$(readlink -f "$1")"; then
        brp_run_hook_impl "$(readlink -f "$1")"
    # probably bogus
    else
        fail "Invalid hook: '$1'.
Not part of '$BR_PROJECT' with the given component selection: $BR_COMPONENTS"
    fi
}

function brp_run_hooks() {
    if [ ! -d "${ROOTDIR}" ]; then
        fail "${ROOTDIR} does not exist."
    elif br_list_directories "hooks" >/dev/null; then
        info "Running hooks..."
        br_for_each_path_iterate_directories "$(br_list_directories "hooks")" \
            brp_run_hook_impl
    else
        info "Skipping hooks, no such directory: hooks"
    fi
}

# Runs a status/config info reporting hook, to be called at the end of the
# brickstrap process. This permits the user to aggregate important info about
# the build in a single, convenient report. (E.g. root passwd, default account
# username+password, hostname, key fingerprints?)
function brp_create_report() {
    if br_list_paths "custom-report.sh" -r >/dev/null; then
        info "Running custom reporting scripts..."
        br_for_each_path "$(br_list_paths custom-report.sh -r)" \
            brp_run_hook_impl 'executing'
        info "Done with custom reporting scripts."
    else
        info "Skipping custom report, no such scripts: custom-report.sh"
    fi
}

function brp_copy_to_tar_only() {
    cp -r "$1/." "${ROOTDIR}/tar-only/"
}

function brp_create_tar() {
    info "Creating tar of rootfs"
    debug "ROOTDIR: ${ROOTDIR}"
    debug "TARBALL: ${TARBALL}"
    [ ! -d "${ROOTDIR}" ] && fail "${ROOTDIR} does not exist."
    [ -z ${FORCE} ] && [ -f "${TARBALL}" ] \
	    && fail "${TARBALL} exists. Use -f option to overwrite."
    info "creating tarball ${TARBALL}"

    info "Excluding files: "
    BRP_EXCLUDE_LIST="${ROOTDIR}/tar-exclude"
    br_cat_files tar-exclude | tee "$BRP_EXCLUDE_LIST" && echo "" # add newline

    brp_determine_qemu
    # test if QEMU should be excluded, if so, append it to exclude list
    if br_get_rootfs_qemu >/dev/null; then
        echo "" >> "$BRP_EXCLUDE_LIST"
        echo "$(br_get_rootfs_qemu)" >> "$BRP_EXCLUDE_LIST"
    fi

    # need to generate tar inside fakechroot
    # so that absolute symlinks are correct

    br_chroot tar cpf /host-rootfs/${TARBALL} --exclude=host-rootfs \
        --exclude=tar-only --exclude=${BRP_EXCLUDE_LIST##$ROOTDIR/} \
        --exclude-from=${BRP_EXCLUDE_LIST##$ROOTDIR} .

    if br_list_directories tar-only >/dev/null; then
        br_for_each_path "$(br_list_directories tar-only)" brp_copy_to_tar_only
        if [ -d "${ROOTDIR}/tar-only" ]; then
            info "Adding tar-only files:"
            br_chroot tar rvpf /host-rootfs/${TARBALL} -C /tar-only .
        fi
    fi
}

function brp_create_rootfs () {
    brp_create_conf
    brp_run_multistrap
    brp_copy_root
    brp_configure_packages
    brp_run_hooks
}

function brp_create_image() {
    info "Creating image file..."
    debug "TARBALL: ${TARBALL}"
    debug "IMAGE: ${IMAGE}"
    debug "IMAGE_FILE_SIZE: ${IMAGE_FILE_SIZE}"
    [ ! -f ${TARBALL} ] && fail "Could not find ${TARBALL}"
    [ -z ${FORCE} ] && [ -f ${IMAGE} ] && \
        fail "${IMAGE} already exists. Use -f option to overwrite."

    # create a disk image with MBR partition table and 2 partitions.
    # ---------------------------------------------
    #   part | type   | fs   | size
    # ---------------------------------------------
    #      1 | boot   | VFAT | 48MB
    #      2 | rootfs | ext4 | ${IMAGE_FILE_SIZE}
    # ---------------------------------------------
    guestfish -N bootroot:vfat:ext4:${IMAGE_FILE_SIZE}:48M:mbr \
         part-set-mbr-id /dev/sda 1 0x0b : \
         set-label /dev/sda2 EV3_FILESYS : \
         mount /dev/sda2 / : \
         tar-in ${TARBALL} / : \
         mkdir-p /media/mmc_p1 : \
         mount /dev/sda1 /media/mmc_p1 : \
         glob mv /boot/flash/* /media/mmc_p1/ : \

    # Hack to set the volume label on the vfat partition since guestfish does
    # not know how to do that. Must be null padded to exactly 11 bytes.
    echo -e -n "EV3_BOOT\0\0\0" | \
        dd of=test1.img bs=1 seek=32811 count=11 conv=notrunc >/dev/null 2>&1

    mv test1.img ${IMAGE}
}

function brp_delete_all() {
    info "Deleting all files..."
    brp_unshare -- rm -rf ${ROOTDIR}
    rm -f ${MULTISTRAPCONF}
    rm -f ${TARBALL}
    rm -f ${IMAGE}
    info "Done."
}

function brp_run_shell() {
    if [ ! -d "${ROOTDIR}" ]; then
        fail "${ROOTDIR} does not exist."
    # permit the user to select the shell manually
    elif [ -n "$1" ]; then
        info "Entering chosen shell: '$1'"
        debian_chroot="brickstrap" PROMPT_COMMAND="" HOME=/root \
            br_chroot_bind "$1"
    # by default assume bash as shell
    else
        info "Entering default shell"
        debian_chroot="brickstrap" PROMPT_COMMAND="" HOME=/root \
            br_chroot_bind bash
    fi
}

function brp_run_command()
{
    [ $# -ge 1 ] && case "$1" in
        create-conf)         brp_create_conf;;
        simulate-multistrap) brp_simulate_multistrap;;
        run-multistrap)      brp_run_multistrap;;
        copy-root)           brp_copy_root;;
        configure-packages)  brp_configure_packages;;
        run-hook)            brp_run_hook "$2";;
        run-hooks)           brp_run_hooks;;
        create-rootfs)       brp_create_rootfs;;
        create-tar)          brp_create_tar;;
        create-image)        brp_create_image;;
        create-report)       brp_create_report;;
        delete)              brp_delete_all;;
        shell)               brp_run_shell "$2";;

        all)
            brp_create_rootfs
            brp_create_tar
            brp_create_image
            brp_create_report
        ;;

        *)
            brp_help "Unknown command: '$1'."
            exit 1
        ;;
    esac
}

function brp_run()
{
    brp_parse_cli_options "$@" && \
    brp_validate_cli_options "$BRP_CMD" "$BRP_CMD_ARG" && \
    brp_init_env && \
    brp_run_command "$BRP_CMD" "$BRP_CMD_ARG"
}

brp_run "$@"
