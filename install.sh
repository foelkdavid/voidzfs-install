#!/usr/bin/env bash

# prevents nuking the wrong system in most cases
# (allowed hostnames are hrmpf and voidlinux)
# set this to false at your own risk ;)
VOID_CHECK_HOSTNAME=true

VOID_REPO_MIRROR=https://repo-de.voidlinux.org/current
VOID_HWCLOCK=UTC

set -Eeo pipefail

# Define Colors for prettier printing
R="\033[0;31m"  # Red
G="\033[0;32m"  # Green
B="\033[0;34m"  # Blue
Y="\033[0;33m"  # Yellow
P="\033[0;35m"  # Purple
LG="\033[1;32m" # Light Green
LB="\033[1;34m" # Light Blue
NC="\033[0m"

# helpers for prettier printing
ok() { printf "  %b %s\n" "${G}✔${NC}" "$1"; }
fail() { printf "  %b %s\n" "${R}✘${NC}" "$1"; }
failhard() { printf "  %b\n" "${R}✘ $1${NC}"; }
info() { printf "%b%s%b\n" "$P" "$1" "$NC"; }
note() { printf "  %b%s%b\n" "$LB" "$1" "$NC"; }

# used in run_prechecks()
check() {
	local desc="$1"
	shift
	if [ "$1" = "hostnamecheck" ] || [ "$1" = "zfscheck" ]; then
		if "$@"; then
			ok "$desc"
		else
			# function already printed failhard
			FAILED=1
		fi
	else
		if "$@" >/dev/null 2>&1; then
			ok "$desc"
		else
			fail "$desc"
			FAILED=1
		fi
	fi
}

hostnamecheck() {
	if [ "${VOID_CHECK_HOSTNAME}" != true ]; then
		return 0
	fi

	local hn
	hn="$(hostname || true)"
	if [ "$hn" = "hrmpf" ] || [ "$hn" = "voidlinux" ]; then
		return 0
	fi
	failhard "Hostname '$hn' not allowed (expected: hrmpf or voidlinux)."
	failhard "This is a safety precaution so you don't wipe the wrong system."
	failhard "Set 'VOID_CHECK_HOSTNAME' at the top of this script to false if you want to continue."
	return 1
}

zfscheck() {
	command -v zgenhostid >/dev/null 2>&1 || {
		failhard "Missing 'zgenhostid' (part of zfs utilities)"
		return 1
	}

	if ! modprobe -n zfs >/dev/null 2>&1; then
		failhard "Kernel module 'zfs' not available on this system"
		return 1
	fi

	return 0
}

servicecheck() {
	local files=(
		"efisync/efisync.sh"
		"efisync/efisync/run"
		"efisync/efisync/log/run"
	)

	for f in "${files[@]}"; do
		[[ -e "$f" ]] || {
			failhard "Missing required file: $f"
			return 1
		}
	done

	return 0
}

run_prechecks() {
	clear
	echo "──────────────────────"
	echo -e "${G}Void-ZFS-Installer${NC}"
	echo "──────────────────────"
	FAILED=0
	info "[Running Pre-Checks]"
	check "System booted in EFI mode" test -d /sys/firmware/efi
	check "Check hostname" hostnamecheck
	check "ZFS utilities and module available" zfscheck
	check "Efisync service available" servicecheck
	check "Connectivity to 1.1.1.1 (ICMP)" ping -c2 -W2 1.1.1.1
	check "DNS resolution (voidlinux.org)" ping -c2 -W2 voidlinux.org

	if [ "$FAILED" -ne 0 ]; then
		echo
		failhard "Some pre-checks failed -> exit"
		exit 1
	fi
}

print_preconf_header() {
	clear
	echo "──────────────────────"
	echo -e "${G}Void-ZFS-Installer${NC}"
	echo "──────────────────────"
	echo -e "${Y}[Configuration]${NC}"
	echo -e "  Xbps-Mirror  -> [ ${Y}${VOID_REPO_MIRROR}${NC} ]"
	echo -e "  HW-CLOCK     -> [ ${Y}${VOID_HWCLOCK}${NC} ]"
	echo -e "  ZFS-Mirror?  -> [ ${Y}${VOID_MIRROR:-}${NC} ]"
	echo -e "  Disk1        -> [ ${Y}${VOID_DISK1:-}${NC} ] ${VOID_DISK1_SIZE}"
	echo -e "  Disk2        -> [ ${Y}${VOID_DISK2:-}${NC} ] ${VOID_DISK2_SIZE}"
	echo -e "  Swap(GB)     -> [ ${Y}${VOID_SWAPSIZE:-}${NC} ] ${VOID_MIRROR:+(per disk)}"
	echo -e "  Hostname:    -> [ ${Y}${VOID_HOSTNAME}${NC} ]"
	echo -e "  Sudo User    -> [ ${Y}${VOID_SUDOUSER:-}${NC} ]"
	echo -e "  Timezone     -> [ ${Y}${VOID_TIMEZONE:-}${NC} ]"
	echo -e "  Keymap       -> [ ${Y}${VOID_KEYMAP:-}${NC} ]"
	echo "──────────────────────"
}

print_postconf_header() {
	clear
	echo "──────────────────────"
	echo -e "${G}Void-ZFS-Installer${NC}"
	echo "──────────────────────"
	echo -e "${Y}[Installing...]${NC}"
}

get_disks() {
	info "[Select Disk $([[ -n ${VOID_DISK1:-} ]] && echo 2 || echo 1)]"

	# only shows relevant info + also removes disks that are not of type DISK (like loop devices etc)
	disklist="$(lsblk -ndo NAME,SIZE,TYPE -dp | awk '$3=="disk"{printf "  %-15s %s\n", $1, $2}')"
	echo -e "${LB}${disklist}${NC}"
	echo "──────────────────────"

	while true; do
		read -rp "Enter the full path of the disk you want to use: " chosen_disk

		if ! lsblk -dno NAME -p | grep -qx "$chosen_disk"; then
			failhard "Invalid disk path: ${chosen_disk}"
		elif [[ $chosen_disk == "${VOID_DISK1:-}" ]]; then
			failhard "You already selected this disk: ${chosen_disk}${NC}"
		else
			disk_var="VOID_DISK1"
			size_var="VOID_DISK1_SIZE"
			[[ -n "${VOID_DISK1:-}" ]] && disk_var="VOID_DISK2"
			[[ -n "${VOID_DISK1:-}" ]] && size_var="VOID_DISK2_SIZE"
			printf -v "$disk_var" "%s" "$chosen_disk"
			read -r disk_size < <(lsblk -dnpo SIZE "$chosen_disk")
			printf -v "$size_var" "(%s)" "$disk_size"
			break
		fi

		sleep 1
		echo -ne "\033[2A\033[0J"
	done
}

mirror_decision() {
	while :; do
		read -rp "Do you want to create a mirror? (y/n) " yn
		[[ -z $yn ]] && echo -ne "\033[1A\033[0J" && continue
		case "${yn,,}" in
		y | yes)
			VOID_MIRROR=true && print_preconf_header && get_disks
			break
			;;
		n | no)
			VOID_MIRROR=false
			VOID_DISK2=none || true
			echo
			break
			;;
		*) echo "Please answer y or n." ;;
		esac
	done
}

get_swapsize() {
	info "[Swap Configuration]"
	note "If you use a mirror, swap will be partitioned on both disks."
	echo "──────────────────────"
	while true; do
		read -rp $'Enter swap size in GB: ' VOID_SWAPSIZE || true
		if [[ "${VOID_SWAPSIZE:-}" =~ ^[0-9]+$ ]] && [ "$VOID_SWAPSIZE" -gt 0 ]; then
			break
		else
			failhard "Invalid input. Please enter a positive integer."
			sleep 1
			echo -ne "\033[2A\033[0J"
		fi
	done
}

# used in get_hostname()
validate_hostname() {
	local h="$1"
	[[ "$h" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$ ]]
}

get_hostname() {
	info "[Set Hostname]"
	note "Validity will be checked automatically.."
	echo "──────────────────────"
	while true; do
		read -rp $'Enter hostname for new system: ' VOID_HOSTNAME || true
		if validate_hostname "$VOID_HOSTNAME"; then
			break
		else
			failhard "Invalid Hostname: $VOID_HOSTNAME"
			sleep 1
			echo -ne "\033[2A\033[0J"
		fi
	done
}

# used in get_sudouser()
validate_username() {
	local u="$1"
	[[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
	[[ "$u" != "root" ]] || return 1
	return 0
}

get_sudouser() {
	info "[Configure sudo-user]"
	note "Your desired username, probably.."
	echo "──────────────────────"
	while true; do
		read -rp $'Enter username for new system: ' VOID_SUDOUSER || true
		if validate_username "$VOID_SUDOUSER"; then
			break
		else
			failhard "Invalid Username: $VOID_SUDOUSER"
			sleep 1
			echo -ne "\033[2A\033[0J"
		fi
	done
}

# used in get_timezone
validate_timezone() {
	[ -f "/usr/share/zoneinfo/$1" ]
}

get_timezone() {
	info "[Configure timezone]"
	note "Located at /usr/share/zoneinfo*"
	note "e.g. Europe/Vienna"
	echo "──────────────────────"
	while true; do
		read -rp $'Enter timezone: ' VOID_TIMEZONE || true
		if validate_timezone "$VOID_TIMEZONE"; then
			break
		else
			failhard "Invalid timezone: $VOID_TIMEZONE"
			sleep 1
			echo -ne "\033[2A\033[0J"
		fi
	done
}

validate_keymap() {
	loadkeys -q "$1" >/dev/null 2>&1 && return 0
	find /usr/share/kbd/keymaps -type f -name "$1.map.gz" -o -name "$1.map" | grep -q . 2>/dev/null
}

get_keymap() {
	info "[Configure keymap]"
	note "e.g. de, de-latin1, us, ..."
	echo "──────────────────────"
	while true; do
		read -rp $'Enter keymap: ' VOID_KEYMAP || true
		if validate_keymap "$VOID_KEYMAP"; then
			break
		else
			failhard "Invalid timezone: $VOID_KEYMAP"
			sleep 1
			echo -ne "\033[2A\033[0J"
		fi
	done
}

confirm_menu() {
	info "[Configuration finished]"
	note "What do you want to do?"
	echo -e "    [${G}c${NC}] Continue with partitioning"
	echo -e "    [${Y}r${NC}] Restart configuration"
	echo -e "    [${R}e${NC}] Exit without changes"
	while true; do
		read -rp "Choose [c/r/e]: " _ans || true
		case "${_ans,,}" in
		c) return 0 ;;
		r) return 10 ;;
		e) return 20 ;;
		esac
	done
}

get_inputs() {
	clear
	run_prechecks
	sleep 1
	print_preconf_header
	get_disks
	print_preconf_header
	mirror_decision
	print_preconf_header
	get_swapsize
	print_preconf_header
	get_hostname
	print_preconf_header
	get_sudouser
	print_preconf_header
	get_timezone
	print_preconf_header
	get_keymap
	print_preconf_header
}

# Formats the following way:
# 512 -> EFI
# $VOID_SWAPSIZE -> swap
# REST OF DISK -> zfs
partition_disks() {

	# Collect disks
	local disks=("$VOID_DISK1")
	[[ "${VOID_MIRROR:-false}" == true && -n "${VOID_DISK2:-}" && "$VOID_DISK2" != "none" ]] && disks+=("$VOID_DISK2")

	for d in "${disks[@]}"; do
		info "[Partitioning $d]"

		# wipe existing layout
		sgdisk --zap-all "$d" >/dev/null || {
			failhard "Wipe failed: $d"
			exit 1
		}

		# create EFI
		sgdisk -n1:1MiB:+512MiB -t1:ef00 -c1:EFI "$d" >/dev/null ||
			{
				failhard "EFI partition failed on $d"
				exit 1
			}
		ok "Created EFI-Partition on $d"

		# create swap
		sgdisk -n2:0:+${VOID_SWAPSIZE}GiB -t2:8200 -c2:swap "$d" >/dev/null ||
			{
				failhard "Swap partition failed on $d"
				exit 1
			}
		ok "Created Swap-Partition on $d"

		# create zfs
		sgdisk -n3:0:-10MiB -t3:bf00 -c3:zfs "$d" >/dev/null ||
			{
				failhard "ZFS partition failed on $d"
				exit 1
			}
		ok "Created ZFS-Partition on $d"

		# reload kernel partition table
		partprobe "$d" >/dev/null 2>&1 || true
	done
}

# used in set_zfs_vars
devpart() {
	local disk="$1" part="${2:-1}" sep=""
	[[ "$disk" =~ ^/dev/(nvme|mmcblk|nbd|loop) ]] && sep="p"
	printf "%s%s%s" "$disk" "$sep" "$part"
}

set_zfs_vars() {
	info "[Setting ZFS-Vars for $VOID_DISK1"
	# Disk 1
	export BOOT_DISK_1="$VOID_DISK1"
	export BOOT_PART_1=1
	export BOOT_DEVICE_1="$(devpart "$VOID_DISK1" 1)"
	ok "BOOT_DEVICE_1 set to $BOOT_DEVICE_1"

	export POOL_DISK_1="$VOID_DISK1"
	export POOL_PART_1=3
	export POOL_DEVICE_1="$(devpart "$VOID_DISK1" 3)"
	ok "POOL_DEVICE_1 set to $POOL_DEVICE_1"

	# Disk 2 (only if set and not "none")
	#
	if [[ -n "${VOID_DISK2:-}" && "$VOID_DISK2" != "none" ]]; then
		info "[Setting ZFS-Vars for $VOID_DISK2"
		export BOOT_DISK_2="$VOID_DISK2"
		export BOOT_PART_2=1
		export BOOT_DEVICE_2="$(devpart "$VOID_DISK2" 1)"
		ok "BOOT_DEVICE_2 set to $BOOT_DEVICE_2"

		export POOL_DISK_2="$VOID_DISK2"
		export POOL_PART_2=3
		export POOL_DEVICE_2="$(devpart "$VOID_DISK2" 3)"
		ok "POOL_DEVICE_2 set to $POOL_DEVICE_2"
	fi
}

wipe_disks() {
	for i in 1 2; do
		local boot pool pooldev
		eval boot="\$BOOT_DISK_${i}"
		eval pool="\$POOL_DISK_${i}"
		eval pooldev="\$POOL_DEVICE_${i}"

		info "[Wiping disk $i: $boot]"
		# Skip if disk i isn't defined
		[[ -z "$boot" || -z "$pool" ]] && continue

		#info "[Wiping disk $i: $boot]"

		# Clear ZFS labels (prefer the pool partition if we have it)
		zpool labelclear -f "${pooldev:-$pool}" >/dev/null 2>&1 || true
		ok "Cleared ZFS labels on ${pooldev:-$pool}"

		# Wipe filesystem signatures
		wipefs -a "$pool" >/dev/null 2>&1 || true
		ok "Wiped filesystem signatures on $pool"

		wipefs -a "$boot" >/dev/null 2>&1 || true
		ok "Wiped filesystem signatures on $boot"

		# Zap partition tables (hard fail if this goes wrong)
		sgdisk --zap-all "$pool" >/dev/null 2>&1 || {
			failhard "Failed to zap partition table on $pool"
			exit 1
		}
		ok "Zapped partition table on $pool"

		sgdisk --zap-all "$boot" >/dev/null 2>&1 || {
			failhard "Failed to zap partition table on $boot"
			exit 1
		}
		ok "Zapped partition table on $boot"

		# Refresh kernel view
		partprobe "$boot" >/dev/null 2>&1 || true
		partprobe "$pool" >/dev/null 2>&1 || true
	done
}

configure_efi_partitions() {
	info "[Installing efibootmgr inside new System]"
	tail_window 4 xchroot /mnt xbps-install -S efibootmgr -y ||
		{
			failhard "Failed to install efibootmgr on the new system"
			exit 1
		}
	echo -ne "\033[4A\033[0J"
	ok "Installed efibootmgr on the new system"

	if [[ "${VOID_MIRROR}" == true ]]; then
		info "[Creating EFI partitions for both disks]"
		mkfs.vfat -F32 "$BOOT_DEVICE_1"
		mkfs.vfat -F32 "$BOOT_DEVICE_2"

		EFI1_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE_1")"
		echo "UUID=$EFI1_UUID /boot/efi vfat defaults,nofail 0 0" >>/mnt/etc/fstab

		EFI2_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE_2")"
		echo "UUID=$EFI2_UUID /boot/efi2 vfat defaults,nofail 0 0" >>/mnt/etc/fstab

		ok "Dual EFI partitions configured"

	else
		info "[Single EFI partition mode]"

		mkfs.vfat -F32 "$BOOT_DEVICE_1"

		EFI_UUID="$(blkid -s UUID -o value "$BOOT_DEVICE_1")"
		echo "UUID=$EFI_UUID /boot/efi vfat defaults 0 0" >>/mnt/etc/fstab

		ok "Single EFI partition configured"
	fi

	info "[Mounting EFI1]"
	mkdir -p /mnt/boot/efi >/dev/null 2>&1
	xchroot /mnt mount /boot/efi ||
		{
			failhard "Failed to mount EFI1"
			exit 1
		}

	info "[Mounting EFI2]"
	mkdir -p /mnt/boot/efi2 >/dev/null 2>&1
	xchroot /mnt mount /boot/efi2 ||
		{
			failhard "Failed to mount EFI2"
			exit 1
		}

	# TODO, ADD LOGIC FOR SINGLE DISK USAGE AND UNIQUE LABELS

	xchroot /mnt mount -t efivarfs none /sys/firmware/efi/efivars
	info "[Adding EFI boot entries]"
	for CUR_DISK in $VOID_DISK1 $VOID_DISK2; do

		xchroot /mnt efibootmgr -c -d "$CUR_DISK" -p 1 \
			-L "ZFSBootMenu ($CUR_DISK)" \
			-l '\EFI\zbm\vmlinuz.EFI' ||
			{
				failhard "Failed adding boot entry for $CUR_DISK"
				exit 1
			}

		ok "Successfully added boot entries for $CUR_DISK"
	done

}

get_zfs_passphrase() {
	info "[Make sure your ZFS passphrase works with a US keyboard layout!]"
	while true; do
		read -rsp "Enter ZFS passphrase: " p1
		echo
		read -rsp "Confirm ZFS passphrase: " p2
		echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && {
			ZFS_PASSPHRASE="$p1"
			return 0
		}
		echo "Passphrases did not match or were empty - try again."
	done

}

get_user_password() {
	while true; do
		read -rsp "Enter User password: " p1
		echo
		read -rsp "Confirm User password: " p2
		echo
		[[ -n "$p1" && "$p1" == "$p2" ]] && {
			USER_PASSWORD="$p1"
			return 0
		}
		echo "Passphrases did not match or were empty - try again."
	done

}

set_user_password() {
	# Requires: $VOID_SUDOUSER, $USER_PASSWORD
	echo "[Setting password for $VOID_SUDOUSER inside chroot]"
	echo -e "${USER_PASSWORD}\n${USER_PASSWORD}" | xchroot /mnt passwd "$VOID_SUDOUSER"
}

# TODO: - optimize parameters here
# TODO: - Test on single disk (lowprio rn)
create_zpool() {
	[[ -z "${POOL_DEVICE_1:-}" ]] && {
		failhard "POOL_DEVICE_1 not set"
		exit 1
	}

	if [[ "${VOID_MIRROR:-false}" == true && -n "${POOL_DEVICE_2:-}" && "$POOL_DEVICE_2" != "none" ]]; then
		info "[Creating encrypted ZFS pool 'zroot' as MIRROR]"

		#    printf '%s\n%s\n' "$ZFS_PASSPHRASE" "$ZFS_PASSPHRASE" | zpool create -f \
		zpool create -f \
			-o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O relatime=on \
			-O dnodesize=auto \
			-O normalization=formD \
			-O mountpoint=none \
			-O encryption=aes-256-gcm \
			-O keylocation=file:///etc/zfs/zroot.key \
			-O keyformat=passphrase \
			zroot mirror \
			/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_1") \
			/dev/disk/by-partuuid/$(blkid -s PARTUUID -o value "$POOL_DEVICE_2") ||
			{
				failhard "ZFS pool creation (mirror) failed"
				unset ZFS_PASSPHRASE
				exit 1
			}

		ok "Created 'zroot' mirror: $POOL_DEVICE_1 + $POOL_DEVICE_2"
	else
		info "[Creating encrypted ZFS pool 'zroot' on SINGLE DISK]"
		failhard "NOT IMPLEMENTED"
		unset ZFS_PASSPHRASE
		exit 1

		printf '%s\n%s\n' "$ZFS_PASSPHRASE" "$ZFS_PASSPHRASE" | zpool create -f \
			-o ashift=12 \
			-O compression=zstd \
			-O acltype=posixacl \
			-O xattr=sa \
			-O relatime=on \
			-O dnodesize=auto \
			-O normalization=formD \
			-O mountpoint=none \
			-O encryption=aes-256-gcm \
			-O keyformat=passphrase \
			-O keylocation=prompt \
			zroot "$POOL_DEVICE_1" >/dev/null 2>&1 ||
			{
				failhard "ZFS pool creation (single) failed"
				unset ZFS_PASSPHRASE
				exit 1
			}

		ok "Created 'zroot' on $POOL_DEVICE_1"
	fi

	# cleanup passphrase from memory
	unset ZFS_PASSPHRASE
}

create_zfs_datasets() {
	info "[Creating initial ZFS datasets]"

	zfs create -o mountpoint=none zroot/ROOT ||
		{
			failhard "Failed to create zroot/ROOT"
			exit 1
		}

	zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/"$ID" ||
		{
			failhard "Failed to create zroot/ROOT/$ID"
			exit 1
		}

	zfs create -o mountpoint=/home zroot/home ||
		{
			failhard "Failed to create zroot/home"
			exit 1
		}

	zpool set bootfs=zroot/ROOT/"$ID" zroot ||
		{
			failhard "Failed to set bootfs property"
			exit 1
		}

	ok "Created initial datasets (bootfs=zroot/ROOT/$ID)"
}

# taken from
# https://docs.zfsbootmenu.org/en/v3.0.x/guides/void-linux/uefi.html
setup_zfs() {
	echo $ZFS_PASSPHRASE >/etc/zfs/zroot.key
	chmod 000 /etc/zfs/zroot.key
	source /etc/os-release
	export ID
	zgenhostid -f
	modprobe zfs
	create_zpool
	create_zfs_datasets
	zpool export zroot
	zpool import -N -R /mnt zroot
	zfs load-key -L file:///etc/zfs/zroot.key zroot
	zfs mount zroot/ROOT/${ID}
	zfs mount zroot/home
	udevadm trigger
}

get_architecture() {
	XBPS_ARCH="$(uname -m)"
	ok "Architecture set to $XBPS_ARCH"
}

tail_window() { # tail_window <N> <command...>
	local N="${1:-5}"
	shift
	local log="/tmp/xbps-install.log"

	# Colors
	LG="\033[1;32m"
	NC="\033[0m"

	"$@" 2>&1 |
		tee "$log" |
		awk -v N="$N" -v LG="$LG" -v NC="$NC" '
      BEGIN{c=0}
      {
        # how many lines were on screen previously
        shown = (c < N ? c : N)
        # move cursor up and clear those lines
        for (i=0; i<shown; i++) printf "\033[1A\033[2K"
        # add new line to ring buffer
        buf[c%N]=$0; c++
        # (re)print the last N (or fewer) lines, colored
        start = (c > N ? c-N : 0)
        for (j=start; j<c; j++) print LG buf[j%N] NC
        fflush()
      }'
	rc=${PIPESTATUS[0]} # exit code
	return "$rc"
}

configure_dracut() {
	info "[Writing dracut config for zfs]"

	{
		echo 'nofsck="yes"'
		echo 'add_dracutmodules+=" zfs "'
		echo 'omit_dracutmodules+=" btrfs "'
		echo 'install_items+=" /etc/zfs/zroot.key "'
	} >>/mnt/etc/dracut.conf.d/zol.conf ||
		{
			failhard "Failed to write to /mnt/etc/dracut.conf.d/zol.conf"
			exit 1
		}
	ok "Wrote dracut config."
}

install_base_system() {
	info "[Get architecture]"
	get_architecture
	info "[Copying xbps-mirror-keys]"
	mkdir -p /mnt/var/db/xbps/keys &&
		cp -r /var/db/xbps/keys /mnt/var/db/xbps ||
		{
			failhard "Failed to copy xbps-mirror-keys"
			exit 1
		}
	ok "Copied xbps-keys into base-system"

	info "[Installing base-system]"
	tail_window 7 xbps-install -S -R "$VOID_REPO_MIRROR" -r /mnt base-system -y ||
		{
			failhard "Failed to install base-system via xbps-install"
			exit 1
		}
	echo -ne "\033[7A\033[0J"
	ok "Installed base-System to /mnt/zfs"
	cp /etc/hostid /mnt/etc
	mkdir -p /mnt/etc/zfs
	cp /etc/zfs/zroot.key /mnt/etc/zfs
	configure_dracut

}

configure_rc_conf() {
	info "[Writing rc.conf]"

	# this syntax is a bit wonky, because treesitter does not like redirects after {} otherwise.
	{
		echo "KEYMAP=\"$VOID_KEYMAP\""
		echo "HARDWARECLOCK=\"$VOID_HWCLOCK\""
	} >/mnt/etc/rc.conf ||
		{
			failhard "Failed to write to /mnt/etc/rc.conf"
			exit 1
		}
	ok "Wrote rc.conf"
}

# used in "configure_glibc_locales"
is_glibc() {
	xchroot /mnt ldd --version 2>&1 | grep -qi 'libc'
}

configure_glibc_locales() {
	if is_glibc; then
		info "[glibc detected: configuring locales]"
		{
			echo "en_US.UTF-8 UTF-8"
			echo "en_US ISO-8859-1"
		} >>/mnt/etc/default/libc-locales >/dev/null 2>&1 ||
			{
				failhard "Failed to write to /mnt/etc/default/libc-locales"
				exit 1
			}
		ok "Wrote /mnt/etc/default/libc-locales"

		xchroot /mnt xbps-reconfigure -f glibc-locales ||
			{
				failhard "Failed to reconfigure glibc-locales"
				exit 1
			}

	else
		info "[musl detected - skipping locale configuration]"
	fi
	ok "Configured Locales"
}

configure_system() {
	info "[Configuring new System]"
	configure_rc_conf
	info "[Setting Timezone to $VOID_TIMEZONE]"
	xchroot /mnt ln -sf "/usr/share/zoneinfo/$VOID_TIMEZONE" /etc/localtime >/dev/null 2>&1 ||
		{
			failhard "Failed to set timezone"
			exit 1
		}
	ok "Set timezone to $VOID_TIMEZONE"
	configure_glibc_locales
	info "[Installing ZFS to new system (Needs compilation so this might take a while)]"
	tail_window 4 xchroot /mnt xbps-install -S zfs -y ||
		{
			failhard "Failed to install zfs on the new system"
			exit 1
		}
	echo -ne "\033[4A\033[0J"
	ok "Installed zfs on the new system"

	info "Configuring ZFS datasets for ZFSBootMenu"
	xchroot /mnt zfs set org.zfsbootmenu:commandline="quiet" zroot/ROOT >/dev/null 2>&1 ||
		{
			failhard "Failed to configure zfs dataset"
			exit 1
		}
}

setup_zfsbootmenu() {
	info "[Installing zfsbootmenu + boot packages inside chroot]"
	tail_window 4 xchroot /mnt xbps-install -S zfsbootmenu systemd-boot-efistub mdadm rsync -y ||
		{
			failhard "Failed to install zfsbootmenu on the new system"
			exit 1
		}
	echo -ne "\033[4A\033[0J"
	ok "Installed zfsbootmenu on the new system"

	# default config but modified to match the guide at:
	# https://docs.zfsbootmenu.org/en/v3.0.x/guides/void-linux/uefi.html
	{
		echo "Global:"
		echo "  ManageImages: true"
		echo "  BootMountPoint: /boot/efi"
		echo "  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d"
		echo "  PreHooksDir: /etc/zfsbootmenu/generate-zbm.pre.d"
		echo "  PostHooksDir: /etc/zfsbootmenu/generate-zbm.post.d"
		echo "  InitCPIOConfig: /etc/zfsbootmenu/mkinitcpio.conf"
		echo "  KeyCache: true"
		echo "Components:"
		echo "  ImageDir: /boot/efi/EFI/zbm"
		echo "  Versions: 3"
		echo "  Enabled: false"
		echo "EFI:"
		echo "  ImageDir: /boot/efi/EFI/zbm"
		echo "  Version: false"
		echo "  Enabled: true"
		echo "  SplashImage: /etc/zfsbootmenu/splash.bmp"
		echo "Kernel:"
		echo "  CommandLine: quiet loglevel=0"
	} >/mnt/etc/zfsbootmenu/config.yaml ||
		{
			failhard "Failed to write to /mnt/zfsbootmenu/config.yaml"
			exit 1
		}
	ok "Wrote config to /mnt/zfsbootmenu/config.yaml"

	xchroot /mnt generate-zbm >/dev/null 2>&1 ||
		{
			failhard "Failed to generate-zbm"
			exit 1
		}
	ok "Generated ZBM"

	# after: ok "Generated ZBM"

	# put a UEFI fallback on disk1 (source ESP)
	mkdir -p /mnt/boot/efi/EFI/BOOT
	cp -f /mnt/boot/efi/EFI/zbm/vmlinuz.EFI /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI

}

setup_user() {
	info "[Creating user: $VOID_SUDOUSER]"

	# Create user and add to wheel group
	xchroot /mnt useradd -m -G wheel "$VOID_SUDOUSER" >/dev/null 2>&1 ||
		{
			failhard "Failed to create user $VOID_SUDOUSER"
			exit 1
		}
	ok "Created user '$VOID_SUDOUSER' and added to group 'wheel'"

	# Prompt for password interactively inside chroot
	note "Set a password for '$VOID_SUDOUSER'"
	set_user_password
	#xchroot /mnt passwd "$VOID_SUDOUSER"

	# Configure sudoers for wheel group
	info "[Configuring sudoers for wheel group]"
	echo "%wheel ALL=(ALL:ALL) ALL" >/mnt/etc/sudoers.d/wheel
	chmod 440 /mnt/etc/sudoers.d/wheel ||
		{
			failhard "Failed to set correct permissions on /mnt/etc/sudoers.d/wheel"
			exit 1
		}
	ok "Configured sudoers (440) for wheel group"
}

sync_esps() {
	[[ "${VOID_MIRROR}" == true && -n "${BOOT_DEVICE_2:-}" && "$BOOT_DEVICE_2" != "none" ]] || return 0
	info "[One-time sync: /boot/efi/EFI/zbm -> /boot/efi2/EFI/zbm]"
	xchroot /mnt rsync -a --delete /boot/efi/ /boot/efi2 ||
		{
			failhard "One-time ESP sync failed"
			exit 1
		}
	ok "Synced secondary ESP"
}

# TODO: add setup for single disk, dont have time rn
setup_swap() {
	export SWAPPART_DISK_1="$(devpart "$VOID_DISK1" 2)"
	export SWAPPART_DISK_2="$(devpart "$VOID_DISK2" 2)"
	sudo mkswap $SWAPPART_DISK_1
	sudo mkswap $SWAPPART_DISK_2
	SWAP1_UUID="$(blkid -s UUID -o value "$SWAPPART_DISK_1")"
	echo "UUID=$SWAP1_UUID none swap defaults,nofail 0 0" >>/mnt/etc/fstab

	SWAP2_UUID="$(blkid -s UUID -o value "$SWAPPART_DISK_2")"
	echo "UUID=$SWAP2_UUID none swap defaults,nofail 0 0" >>/mnt/etc/fstab
}

install_efisync() {
	info ["Installing efisync-runit-service"]

	tail_window 4 xchroot /mnt xbps-install -S rsync inotify-tools util-linux -y ||
		{
			failhard "Failed to install efibootmgr on the new system"
			exit 1
		}

	cp -r $PWD/efisync/efisync /mnt/etc/sv/ ||
		{
			failhard "Failed to copy efisync runit service"
			exit 1
		}
	ok "/mnt/etc/sv/efisync"

	cp $PWD/efisync/efisync.sh /mnt/usr/local/bin ||
		{
			failhard "Failed to copy efisync script"
			exit 1
		}
	ok "/mnt/usr/local/bin/efisync.sh"

	chmod +x /mnt/etc/sv/efisync/run /mnt/etc/sv/efisync/conf /mnt/etc/sv/efisync/run/log /mnt/usr/local/bin/efisync.sh ||
		{
			failhard "Failed to make efisync executable"
			exit 1
		}
	ok "ensure executable perimssions for efisync"

	xchroot /mnt ln -s /etc/sv/efisync /var/service/ ||
		{
			failhard "Failed to link efisync-runit-service"
			exit 1
		}
	ok "linked efisync-runit service"

}

# ENTRY:
while true; do
	get_inputs
	if confirm_menu; then rc=0; else rc=$?; fi
	case "$rc" in
	10) info "[Restarting configuration]" && unset VOID_MIRROR VOID_DISK1 VOID_DISK1_SIZE VOID_DISK2 VOID_DISK2_SIZE VOID_SWAPSIZE VOID_HOSTNAME VOID_SUDOUSER VOID_TIMEZONE VOID_KEYMAP && continue ;;
	20) exit 0 ;;
	0) break ;;
	esac
done
print_postconf_header
echo
get_user_password
echo
get_zfs_passphrase
print_postconf_header
set_zfs_vars
wipe_disks
partition_disks
setup_zfs
install_base_system
configure_efi_partitions
configure_system
setup_zfsbootmenu
setup_swap
setup_user
echo $VOID_HOSTNAME >/mnt/etc/hostname
sync_esps
install_efisync
umount -n -R /mnt
zpool export zroot
