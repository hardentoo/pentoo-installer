# partition_gen_key()
# Generate a key, optionnaly encrypt it with gpg
# $1 use gpg or not
# $2 gpg key to store
#
# return !=0 on failure (including user abort with ERROR_CANCEL=64)
#
partition_gen_key() {
	# check input
	check_num_args "${FUNCNAME}" 2 $# || return $?
	local _BASENAME2=$(basename ${2}) || return $?
    if [ ${1} = "yes" ]; then
        show_dialog --msgbox "We will now generate a GPG-encrypted luks key for ${_BASENAME2}" 0 0 || return $?
        head -c60 /dev/urandom | base64 | head -n1 | tr -d '\n' > "${2}" || return $?
        gpg --symmetric --cipher-algo aes256 --armor "${2}" || return $?
    else
        head -c60 /dev/urandom | base64 | head -n1 | tr -d '\n' > "${2}" || return $?
    fi
	return 0
}

# partition_mkfs()
# Create and mount filesystems in our destination system directory.
#
# arguments (all required):
#  domk: Whether to make the filesystem or use what is already there
#  device: Device filesystem is on
#  fstype: type of filesystem located at the device (or what to create)
#  dest: Mounting location for the destination system
#  mountpoint: Mount point inside the destination system, e.g. '/boot'
# 
# returns: 0 on success, anything else is an error
#
partition_mkfs() {
	# check input
	check_num_args "${FUNCNAME}" 5 $# || return $?
    local _DOMK=$1
    local _DISC=$2
    local _FSTYPE=$3
    local _DEST=$4
    local _MOUNTPOINT=$5
	local _RET=""
	# TODO handle this global var
	# S_FDE=1
    case ${_FSTYPE} in
        *-luks)
		local _LUKSNAME=""
		local _LUKSKEY=""
		local _DOGPG=""
		if [ ${_MOUNTPOINT} = "/" ]; then
			_LUKSNAME="root_partition"
			_DOGPG="YES"
		else
			_LUKSNAME=`basename $5` || return $?
			show_dialog --defaultno --yesno "Do you want to use GPG encrypted key for this partition ($_MOUNTPOINT) ?" 0 0 && _DOGPG="YES"
		fi
		_LUKSKEY=/tmp/${_LUKSNAME}
		if [ ${_DOGPG} = "YES" ]; then
			partition_gen_key yes ${_LUKSKEY} \
				&& _LUKSKEY=${_LUKSKEY}.asc \
				|| return $?
			echo -e "target=${_LUKSNAME}\nsource='${_DISC}'\nkey='/etc/keys/`basename ${_LUKSKEY}`:gpg'\n" >>/tmp/.dmcrypt || return $?
			partition_luks_fmt yes ${_DISC} ${_LUKSKEY} \
				&& partition_luks_open yes ${_DISC} ${_LUKSKEY} ${_LUKSNAME} \
				&& _DISC=/dev/mapper/${_LUKSNAME} \
				&& _FSTYPE=${_FSTYPE/-luks/} \
				|| return $?
		else
			partition_gen_key no ${_LUKSKEY} || return $?
			echo -e "target=${_LUKSNAME}\nsource='${_DISC}'\nkey='/etc/keys/`basename ${_LUKSKEY}`'\n" >>/tmp/.dmcrypt || return $?
			partition_luks_fmt no ${_DISC} ${_LUKSKEY} \
				&& partition_luks_open no ${_DISC} ${_LUKSKEY} ${_LUKSNAME} \
				&& _DISC=/dev/mapper/${_LUKSNAME} \
				&& _FSTYPE=${_FSTYPE/-luks/} \
				|| return $?
		fi
		;;
    esac
    echo "$@" >> $LOG
    # we have two main cases: "swap/crypt-swap" and everything else.
    if [ "${_FSTYPE}" = "swap" ]; then
        swapoff ${_DISC} &>/dev/null
        if [ "${_DOMK}" = "yes" ]; then
            mkswap ${_DISC} >>"${LOG}" 2>&1 || return $?
        fi
        swapon ${_DISC} >>"${LOG}" 2>&1 || return $?
    elif [ "${_FSTYPE}" = "crypt-swap" ]; then
        swapoff ${_DISC} &>/dev/null
        if [ "${_DOMK}" = "yes" ]; then
            cryptsetup create -c aes-xts-plain64:sha512 -s 512 -d /dev/urandom swap ${_DISC} >>"${LOG}" 2>&1 \
				&& echo -e "swap=swap\nsource='${_DISC}'\n" >>/tmp/.dmcrypt \
				&& _DISC="/dev/mapper/swap" \
				&& mkswap ${_DISC} >>"${LOG}" 2>&1 \
				&& _FSTYPE="swap" \
				|| return $?
        fi
        swapon ${_DISC} >>"${LOG}" 2>&1 || return $?
    else
        # make sure the _FSTYPE is one we can handle
        local _KNOWNFS=0
        for fs in xfs jfs reiserfs ext2 ext3 ext4 vfat; do
            [ "${_FSTYPE}" = "${fs}" ] && _KNOWNFS=1 && break
        done
        if [ $_KNOWNFS -eq 0 ]; then
            show_dialog --msgbox "unknown _FSTYPE ${_FSTYPE} for ${_DISC}" 0 0
            return 1
        fi
        # if we were tasked to create the filesystem, do so
        if [ "${_DOMK}" = "yes" ]; then
            case ${_FSTYPE} in
                xfs)      mkfs.xfs -f ${_DISC} >>"${LOG}" 2>&1; _RET=$? ;;
                jfs)      yes | mkfs.jfs ${_DISC} >>"${LOG}" 2>&1; _RET=$? ;;
                reiserfs) yes | mkreiserfs ${_DISC} >>"${LOG}" 2>&1; _RET=$? ;;
                ext2)     mke2fs "${_DISC}" -F >>"${LOG}" 2>&1; _RET=$? ;;
                ext3)     mke2fs -j ${_DISC} -F >>"${LOG}" 2>&1; _RET=$? ;;
                ext4)     mke2fs -t ext4 ${_DISC} -F >>"${LOG}" 2>&1; _RET=$? ;;
                vfat)     mkfs.vfat ${_DISC} >>"${LOG}" 2>&1; _RET=$? ;;
                # don't handle anything else here, we will error later
            esac
            if [ $_RET != 0 ]; then
                show_dialog --msgbox "Error creating filesystem ${_FSTYPE} on ${_DISC}" 0 0
                return 1
            fi
            sleep 2
        fi
        # create our mount directory
        mkdir -p ${_DEST}${_MOUNTPOINT} || return $?
        # mount the bad boy
        mount -t ${_FSTYPE} ${_DISC} ${_DEST}${_MOUNTPOINT} >>"${LOG}" 2>&1
        if [ $? != 0 ]; then
            show_dialog --msgbox "Error mounting ${_DEST}${_MOUNTPOINT}" 0 0
            return 1
        fi
    fi
    # add to temp fstab
    echo -n "${_DISC} ${_MOUNTPOINT} ${_FSTYPE} defaults 0 " >>/tmp/.fstab || return $?
    if [ "${_FSTYPE}" = "swap" ]; then
        echo "0" >>/tmp/.fstab || return $?
    else
        echo "1" >>/tmp/.fstab || return $?
    fi
	return 0
}
# end of partition_mkfs()

# partition_luks_fmt()
# format a luks partition. Cipher and hash chosen arbitrarily
# $1 use GPG
# $2 device to luksformat
# $3 key
#
# return !=0 on failure (including user abort)
#
partition_luks_fmt() {
	# check input
	check_num_args "${FUNCNAME}" 3 $# || return $?
	local _BASENAME3=$(basename ${3/.asc/}) || return $?
    if [ ${1} = "yes" ]; then
        show_dialog --msgbox "Please enter the GPG key for ${_BASENAME3}" 0 0 || return $?
        gpg --decrypt "${3}" | cryptsetup -h sha512 -c aes-xts-plain64 -s 512 luksFormat --align-payload=8192 "${2}" || return $?
    else
        cat "${3}" | cryptsetup -h sha512 -c aes-xts-plain64 -s 512 luksFormat --align-payload=8192 "${2}" || return $?
    fi
	return 0
}

# partition_luks_open()
# open a luks partition
# $1 use GPG
# $2 device to luksformat
# $3 gpg key
# $4 name of new device
#
partition_luks_open() {
	# check input
	check_num_args "${FUNCNAME}" 4 $# || return $?
	local _RET=
	# check if name of device already exists, for ex. from a previous install attempt ;)
	# `cryptsetup status` returns 0 if active, 4 if not existent
	cryptsetup status "${4}" 1>/dev/null
	_RET=$?
	if [ "${_RET}" -eq 0 ]; then
		cryptsetup close "${4}" || return $?
	elif [ "${_RET}" -ne 4 ]; then
		return "${_RET}"
	fi
    if [ ${1} = "yes" ]; then
        show_dialog --msgbox "Please enter the GPG key for `basename ${3/.asc/}` (last time :-)" 0 0 || return $?
        gpg --decrypt "${3}" | cryptsetup luksOpen "${2}" "${4}" || return $?
    else
        cat "${3}" | cryptsetup luksOpen "${2}" "${4}" || return $?
    fi
	return 0
}
