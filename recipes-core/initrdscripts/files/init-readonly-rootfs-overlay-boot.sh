#!/bin/sh

# Enable strict shell mode
set -euo pipefail

PATH=/sbin:/bin:/usr/sbin:/usr/bin

MOUNT="/bin/mount"
FSCK="/sbin/fsck"
GREP="/bin/grep"
MKDIR="/bin/mkdir"
EXPR="/usr/bin/expr"
ECHO="/bin/echo"
BASENAME="/usr/bin/basename"
READLINK="/usr/bin/readlink"
CAT="/bin/cat"
MODPROBE="/sbin/modprobe"
CMP="/usr/bin/cmp"

INIT="/lib/systemd/systemd"
ROOT_ROINIT="/sbin/init"

ROOT_MOUNT="/mnt"
ROOT_RODEVICE=""
ROOT_RWDEVICE=""
ROOT_ROMOUNT="/media/rfs/ro"
ROOT_RWMOUNT="/media/rfs/rw"
ROOT_RWRESET="no"
DATA_MOUNT_DEVICE="/dev/mmcblk2p4"

ROOT_ROFSTYPE=""
ROOT_ROMOUNTOPTIONS="bind"
ROOT_ROMOUNTOPTIONS_DEVICE=""

ROOT_RWFSTYPE=""
ROOT_RWMOUNTOPTIONS="rw,noatime,mode=755 tmpfs"
ROOT_RWMOUNTOPTIONS_DEVICE=""

early_setup() {
	${MKDIR} -p /proc
	${MKDIR} -p /sys
	${MOUNT} -t proc proc /proc
	${MOUNT} -t sysfs sysfs /sys
	${GREP} -w "/dev" /proc/mounts >/dev/null || ${MOUNT} -t devtmpfs none /dev
}

find_root_rodevice() {
	arg=${*}
	optarg=$(${EXPR} "x${arg}" : 'x[^=]*=\(.*\)' || ${ECHO} '')
	case ${arg} in
		LABEL=*)
			device="$(${BASENAME} "$(${READLINK} /dev/disk/by-label/"${optarg}")")"
			${ECHO} "/dev/${device}"
			;;
		PARTUUID=*)
			device="$(${BASENAME} "$(${READLINK} /dev/disk/by-partuuid/"${optarg}")")"
			${ECHO} "/dev/${device}"
			;;
		UUID=*)
			device="$(${BASENAME} "$(${READLINK} /dev/disk/by-uuid/"${optarg}")")"
			${ECHO} "/dev/${device}"
			;;
	esac
}

check_etc_hostname() {
	rpmb_device="/dev/mmcblk2rpmb"
	mmc_output="$(/usr/bin/mmc rpmb read-block ${rpmb_device} 0x0 1 - | sed 's/,/ /g' | tr -s '\0' '\n')"
	hostname_file="${ROOT_MOUNT}/etc/hostname"
	kernel_hostname_file="/proc/sys/kernel/hostname"

	if [ -n "${mmc_output}" ] ; then
		for entry in ${mmc_output}
		do
			export "${entry?}"
		done

		if [ -f ${hostname_file} ]
		then
			if ! ${GREP} -q "${SERIAL}" ${hostname_file}
			then
				${ECHO} "${SERIAL}" > ${hostname_file}
			fi
		fi

		kernel_hostname=$(cat ${kernel_hostname_file})
		if [ "${kernel_hostname}" != "${SERIAL}" ]
		then
			${ECHO} "${SERIAL}" > ${kernel_hostname_file}
		fi
	fi
}

read_args() {
	[ -z "${CMDLINE+x}" ] && CMDLINE=$(${CAT} /proc/cmdline)
	for arg in ${CMDLINE}; do
		# Set optarg to option parameter, and '' if no parameter was
		# given
		optarg=$(${EXPR} "x${arg}" : 'x[^=]*=\(.*\)' || ${ECHO} '')
		case ${arg} in
			root=*)
				ROOT_RODEVICE=${optarg} ;;
			rootfstype=*)
				ROOT_ROFSTYPE="${optarg}"
				${MODPROBE} "${optarg}" 2> /dev/null || \
					log "Could not load ${optarg} module";;
			rootinit=*)
				ROOT_ROINIT=${optarg} ;;
			rootoptions=*)
				ROOT_ROMOUNTOPTIONS_DEVICE="${optarg}" ;;
			rootrw=*)
				ROOT_RWDEVICE=${optarg} ;;
			rootrwfstype=*)
				ROOT_RWFSTYPE="${optarg}"
				${MODPROBE} "${optarg}" 2> /dev/null || \
					log "Could not load ${optarg} module";;
			rootrwreset=*)
				ROOT_RWRESET=${optarg} ;;
			rootrwoptions=*)
				ROOT_RWMOUNTOPTIONS_DEVICE="${optarg}" ;;
			init=*)
				INIT=${optarg} ;;
		esac
	done
}

fatal() {
	${ECHO} "rorootfs-overlay: ${1}" >"${CONSOLE}"
	${ECHO} >"${CONSOLE}"
	exec sh
}

log() {
	${ECHO} "rorootfs-overlay: ${1}" >"${CONSOLE}"
}

early_setup

[ -z "${CONSOLE+x}" ] && CONSOLE="/dev/console"

read_args

mount_and_boot() {
	# run fsck on ROOT_RODEVICE
	${FSCK} -p ${ROOT_RODEVICE} > /dev/null 2>&1
	# run fsck on ROOT_RWDEVICE
	${FSCK} -p ${ROOT_RWDEVICE} > /dev/null 2>&1

	${MKDIR} -p ${ROOT_MOUNT} ${ROOT_ROMOUNT} ${ROOT_RWMOUNT}

	# Build mount options for read only root file system.
	# If no read-only device was specified via kernel command line, use
	# current root file system via bind mount.
	ROOT_ROMOUNTPARAMS_BIND="-o ${ROOT_ROMOUNTOPTIONS} /"
	if [ -n "${ROOT_RODEVICE}" ]; then
		if [ -n "${ROOT_ROMOUNTOPTIONS_DEVICE}" ]; then
			ROOT_ROMOUNTPARAMS="-o ${ROOT_ROMOUNTOPTIONS_DEVICE} ${ROOT_RODEVICE}"
			if [ -n "${ROOT_ROFSTYPE}" ]; then
				ROOT_ROMOUNTPARAMS="-t ${ROOT_ROFSTYPE} ${ROOT_ROMOUNTPARAMS}"
			fi
		else
			ROOT_ROMOUNTPARAMS="${ROOT_RODEVICE}"
		fi
	else
		ROOT_ROMOUNTPARAMS="${ROOT_ROMOUNTPARAMS_BIND}"
	fi

	# Mount root file system to new mount-point, if unsuccessful, try bind
	# mounting current root file system.
	CMD="${MOUNT} ${ROOT_ROMOUNTPARAMS} ${ROOT_ROMOUNT}"
	if ! ${CMD} 2>/dev/null
	then
		CMD="${MOUNT} ${ROOT_ROMOUNTPARAMS_BIND} ${ROOT_ROMOUNT}"
		if ! ${CMD}
		then
			fatal "Could not mount read-only rootfs"
		fi
	fi

	# Remounting root file system as read only.
	CMD="${MOUNT} -o remount,ro ${ROOT_ROMOUNT}"
	if ! ${CMD}
	then
		fatal "Could not remount read-only rootfs as read only"
	fi

	# If future init is the same as current file, use $ROOT_ROINIT
	# Tries to avoid loop to infinity if init is set to current file via
	# kernel command line
	if ${CMP} -s "${0}" "${INIT}"
	then
		INIT="${ROOT_ROINIT}"
	fi

	# Build mount options for read write root file system.
	# If a read-write device was specified via kernel command line, use
	# it, otherwise default to tmpfs.
	if [ -n "${ROOT_RWDEVICE}" ]
	then
		if [ -n "${ROOT_RWMOUNTOPTIONS_DEVICE}" ]
		then
			ROOT_RWMOUNTPARAMS="-o ${ROOT_RWMOUNTOPTIONS_DEVICE} ${ROOT_RWDEVICE}"
		else
			ROOT_RWMOUNTPARAMS=" ${ROOT_RWDEVICE}"
		fi
		if [ -n "${ROOT_RWFSTYPE}" ]
		then
			ROOT_RWMOUNTPARAMS="-t ${ROOT_RWFSTYPE} ${ROOT_RWMOUNTPARAMS}"
		fi
	else
		ROOT_RWMOUNTPARAMS="-t tmpfs -o ${ROOT_RWMOUNTOPTIONS}"
	fi

	# Mount read-write file system into initram root file system
	CMD="${MOUNT} ${ROOT_RWMOUNTPARAMS} ${ROOT_RWMOUNT}"
	if ! ${CMD}
	then
		fatal "Could not mount read-write rootfs"
	fi

	# Reset read-write file system if specified
	if [ "yes" = "$ROOT_RWRESET" ] && [ -n "${ROOT_RWMOUNT}" ]
	then
		rm -rf "${ROOT_RWMOUNT:?}/*"
	fi

	# Determine which unification file system to use
	union_fs_type=""
	if ${GREP} -w "overlay" /proc/filesystems >/dev/null
	then
		union_fs_type="overlay"
	elif ${GREP} -w "aufs" /proc/filesystems >/dev/null
	then
		union_fs_type="aufs"
	else
		union_fs_type=""
	fi

	# Create/Mount overlay root file system
	case ${union_fs_type} in
		"overlay")
			${MKDIR} -p ${ROOT_RWMOUNT}/upperdir ${ROOT_RWMOUNT}/work
			${MOUNT} -t overlay overlay \
				-o "$(printf "%s%s%s" \
					"lowerdir=${ROOT_ROMOUNT}," \
					"upperdir=${ROOT_RWMOUNT}/upperdir," \
					"workdir=${ROOT_RWMOUNT}/work")" \
				${ROOT_MOUNT}
			;;
		"aufs")
			${MOUNT} -t aufs i\
				-o "dirs=${ROOT_RWMOUNT}=rw:${ROOT_ROMOUNT}=ro" \
				aufs ${ROOT_MOUNT}
			;;
		"")
			fatal "No overlay filesystem type available"
			;;
	esac

	# Move read-only and read-write root file system into the overlay
	# file system
	${MKDIR} -p ${ROOT_MOUNT}/${ROOT_ROMOUNT} ${ROOT_MOUNT}/${ROOT_RWMOUNT}
	${MOUNT} -n --move ${ROOT_ROMOUNT} ${ROOT_MOUNT}${ROOT_ROMOUNT}
	${MOUNT} -n --move ${ROOT_RWMOUNT} ${ROOT_MOUNT}${ROOT_RWMOUNT}

	# Update /etc/hostname
	check_etc_hostname

	# switch to actual init in the overlay root file system
	exec switch_root ${ROOT_MOUNT} "${INIT}" 2>/dev/null ||
		fatal "Couldn't chroot, dropping to shell"
}

mount_and_boot
