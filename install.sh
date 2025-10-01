#!/usr/bin/env bash
# shellcheck disable=SC2155

set -Eeuo pipefail

# ---------------------------
# Colors & Symbols
# ---------------------------
RED="\033[0;31m"
GREEN="\033[0;32m"
LGREEN="\033[1;32m"
YELLOW="\033[0;33m"
LBLUE="\033[1;34m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
NC="\033[0m"

ok="${GREEN}✔${NC}"
fail="${RED}✘${NC}"

FAILED=0  # for pre-checks

# ---------------------------
# UI helpers
# ---------------------------
header() {
  clear
  echo -e "${GREEN}Void-ZFS-Installer${NC}"
  echo "--------------------"
  echo -e "${PURPLE}[Configuration]${NC}"
  echo -e "  ZFS-Mirror?  -> [ ${YELLOW}${MIRROR:-}${NC} ]"
  echo -e "  Disk1        -> [ ${YELLOW}${DISK1:-}${NC} ]" # TODO: add size
  echo -e "  Disk2        -> [ ${YELLOW}${DISK2:-}${NC} ]" # TODO: add size
  echo -e "  Swap(GB)     -> [ ${YELLOW}${SWAPSIZE:-}${NC} ] ${MIRROR:+(per disk)}"
  echo -e "  Hostname:    -> [ ${YELLOW}${VOID_HOSTNAME}${NC} ]"
  echo -e "  Sudo User    -> [ ${YELLOW}${VOID_USER:-}${NC} ]"
  echo -e "  Timezone     -> [ ${YELLOW}${VOID_TIMEZONE:-}${NC} ]"
  echo -e "  Keymap       -> [ ${YELLOW}${VOID_KEYMAP:-}${NC} ]"
  echo
}

say_ok()   { printf "  %b %s\n" "$ok" "$1";   sleep 0.04; }
say_fail() { printf "  %b %s\n" "$fail" "$1"; sleep 0.04; }
info()     { printf "%b%s%b\n" "$PURPLE" "$1" "$NC"; }

# Pretty logs that go to STDERR (so they don't pollute command substitution)
log_ok()   { printf "  %b %s\n" "$ok" "$1" >&2; }
log_fail() { printf "  %b %s\n" "$fail" "$1" >&2; }
log_info() { printf "%b%s%b\n" "$PURPLE" "$1" "$NC" >&2; }

repaint_section() {
  header
  info "[Swap / User / Locale]"
}

# TODO: VIBE CODED BS
prompt_yes_no() {
  local q="$1" def="${2:-n}" ans
  local hint="[y/N]"
  [ "$def" = "y" ] && hint="[Y/n]"
  read -rp "$q $hint: " ans || true # MAKE THIS COLORED
  case "${ans:-$def}" in y|Y) return 0 ;; *) return 1 ;; esac
}

confirm_menu() {
  echo -e "${PURPLE}[Configuration finished]${NC}"
  echo "  What do you want to do?"
  echo -e "    [${GREEN}c${NC}] Continue with partitioning"
  echo -e "    [${YELLOW}r${NC}] Restart configuration"
  echo -e "    [${RED}e${NC}] Exit without changes"
  while true; do
    read -rp "Choose [c/r/e]: " _ans || true
    case "${_ans,,}" in
      c) return 0 ;;
      r) return 10 ;;
      e) return 20 ;;
    esac
  done
}

# ---------------------------
# Checks
# ---------------------------
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    say_ok "$desc"
  else
    say_fail "$desc"
    FAILED=1
  fi
}

run_prechecks() {
  info "[Running Pre-Checks]"
  check "System booted in EFI mode" test -d /sys/firmware/efi
  check "Connectivity to 1.1.1.1 (ICMP)" ping -c2 -W2 1.1.1.1
  check "DNS resolution (voidlinux.org)" ping -c2 -W2 voidlinux.org
  if [ "$FAILED" -ne 0 ]; then
    echo -e "${RED}Some pre-checks failed -> exit${NC}"
    exit 1
  fi
}

# ---------------------------
# Disk listing
# ---------------------------
_list_disk_nodes() {
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}'
}

list_disks() {
  local n size model
  while read -r n; do
    size=$(lsblk -dn -o SIZE "$n" 2>/dev/null)
    model=$(lsblk -dn -o MODEL "$n" 2>/dev/null)
    printf "    %-20s %-8s %s\n" "$n" "$size" "$model"
  done < <(_list_disk_nodes)
}

ds()  { lsblk -dn -o SIZE "$1" 2>/dev/null || true; }
dsb() { lsblk -dn -o SIZE -b "$1" 2>/dev/null || echo 0; }

is_whole_disk() {
  local name; name=$(basename "$1")
  lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -qw -- "$name"
}

# ---------------------------
# Input helpers
# ---------------------------
get_disk() {
  # TODO: Remove already selected disk from available disks on disk 2 selection
  local var="$1" picked
  while true; do
    header
    info "[Select Disk]"
    echo -e "  Available disks:"
    local listing; listing="$(list_disks)"
    if [ -z "$listing" ]; then
      echo -e "${YELLOW}(No disks detected)${NC}\n"
    else
      echo -e "${LBLUE}${listing}${NC}\n"
    fi
    read -rp $'Enter path for disk: ' picked
    picked="${picked//[[:space:]]/}"
    [ -z "${picked}" ] && { say_fail "Empty input. Press Enter to retry."; read -r; continue; }
    if ! is_whole_disk "$picked"; then
      say_fail "$picked is not a valid whole disk. Press Enter to retry."
      read -r; continue
    fi
    if [ "$var" = "DISK2" ] && [ -n "${DISK1:-}" ] && [ "$picked" = "$DISK1" ]; then
      say_fail "You already selected $picked as DISK1. Choose a different disk. Press Enter to retry."
      read -r; continue
    fi
    say_ok "Using $picked ($(ds "$picked"))"
    printf -v "$var" "%s" "$picked"
    header  # repaint table immediately
    break
  done
}

get_mirror_choice() {
  echo
  if prompt_yes_no 'Add a second disk for mirroring?' n; then
    MIRROR=true
    echo -e "${YELLOW}Note: Swap size is PER DISK when mirroring.${NC}"
    get_disk DISK2
    local b1 b2; b1=$(dsb "$DISK1"); b2=$(dsb "$DISK2")
    if [ "$b1" -ne "$b2" ]; then
      echo -e "${YELLOW}! Warning: disk sizes differ ($(ds "$DISK1") vs $(ds "$DISK2")). Usable size will match the smaller.${NC}\n"
    fi
  else
    MIRROR=false; unset DISK2 || true
    echo
  fi
}

get_swapsize() {
  while true; do
    read -rp $'  Enter swap size in GB: ' SWAPSIZE || true
    if [[ "${SWAPSIZE:-}" =~ ^[0-9]+$ ]] && [ "$SWAPSIZE" -gt 0 ]; then
      say_ok "Using ${SWAPSIZE}GB swap ${MIRROR:+(per disk)}"
      header
      break
    else
      say_fail "Invalid input. Please enter a positive integer."
    fi
  done
}

validate_hostname() {
  # TODO
  return 0
}

get_hostname() {
  while true; do
    read -rp $'  Enter hostname for new system: ' VOID_HOSTNAME || true
    if validate_hostname "$VOID_HOSTNAME"; then
      say_ok "Hostname OK: $VOID_HOSTNAME"
      header
      break
    else
      say_fail "Invalid Hostname: $VOID_HOSTNAME"
    fi
  done
}

validate_username_syntax() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  [[ "$u" != "root" ]] || return 1
  return 0
}

get_sudo_user() {
  while true; do
    read -rp $'  Enter sudo username: ' VOID_USER || true
    VOID_USER="${VOID_USER//[[:space:]]/}"
    if validate_username_syntax "$VOID_USER"; then
      if getent passwd "$VOID_USER" >/dev/null 2>&1; then
        echo -e "  ${YELLOW}! User '$VOID_USER' already exists; will reuse.${NC}"
      fi
      say_ok "Username OK: $VOID_USER"
      header
      break
    else
      say_fail "Invalid username. Use lowercase letters/digits/_/-, start with letter/_ , max 32 chars, not 'root'."
    fi
  done
}

validate_timezone() { [ -f "/usr/share/zoneinfo/$1" ]; }

get_timezone() {
  while true; do
    read -rp $'  Enter timezone: ' VOID_TIMEZONE || true
    VOID_TIMEZONE="${VOID_TIMEZONE:-Europe/Vienna}"
    if validate_timezone "$VOID_TIMEZONE"; then
      say_ok "Timezone OK: $VOID_TIMEZONE"
      header
      break
    else
      say_fail "Timezone not found under /usr/share/zoneinfo."
    fi
  done
}

validate_keymap() {
  loadkeys -q "$1" >/dev/null 2>&1 && return 0
  find /usr/share/kbd/keymaps -type f -name "$1.map.gz" -o -name "$1.map" | grep -q . 2>/dev/null
}

get_keymap() {
  while true; do
    read -rp $'  Enter console keymap: ' VOID_KEYMAP || true
    VOID_KEYMAP="${VOID_KEYMAP:-us}"
    if validate_keymap "$VOID_KEYMAP"; then
      say_ok "Keymap OK: $VOID_KEYMAP"
      header
      break
    else
      say_fail "Keymap not found. Try values like 'us', 'de', 'de-nodeadkeys'."
    fi
  done
}

# ---------------------------
# Partition helpers
# ---------------------------
partpath() {
  local disk="$1" part="$2"
  if [[ "$disk" =~ nvme || "$disk" =~ mmcblk ]]; then
    printf "%sp%s" "$disk" "$part"
  else
    printf "%s%s" "$disk" "$part"
  fi
}

run_quiet() { "$@" >/dev/null 2>&1; }

wipe_and_gpt() {
  local d="$1"
  info "[Disk Prep: ${d}]"
  echo "  Wiping partition tables and filesystem signatures..."
  run_quiet sgdisk --zap-all "$d"
  run_quiet wipefs -af "$d"
  say_ok "Disk wiped"
  echo "  Creating new GPT table..."
  run_quiet sgdisk -og "$d"
  run_quiet partprobe "$d"
  say_ok "GPT table created"
  echo
}

# ---------------------------
# Partitioning branches
# ---------------------------
partition_single() {
  header
  info "[Partitioning: single disk]"
  local d="$DISK1"

  wipe_and_gpt "$d"
  echo "  Creating partition layout:"
  echo "    1: EFI (512MiB)"
  echo "    2: SWAP (${SWAPSIZE}GiB)"
  echo "    3: ZFS (rest)"
  run_quiet sgdisk -n1:0:+512MiB -t1:EF00 -c1:"EFI System" "$d"
  run_quiet sgdisk -n2:0:+${SWAPSIZE}GiB -t2:8200 -c2:"Linux swap" "$d"
  run_quiet sgdisk -n3:0:0 -t3:BF01 -c3:"ZFS" "$d"
  run_quiet partprobe "$d"; sleep 1
  say_ok "Partitions created"
  echo
}

partition_mirror() {
  header
  info "[Partitioning: mirror]"
  local d1="$DISK1" d2="$DISK2"

  wipe_and_gpt "$d1"
  wipe_and_gpt "$d2"
  echo "  Creating partition layout on both disks..."
  for d in "$d1" "$d2"; do
    run_quiet sgdisk -n1:0:+512MiB -t1:FD00 -c1:"EFI RAID" "$d"
    run_quiet sgdisk -n2:0:+${SWAPSIZE}GiB -t2:8200 -c2:"Linux swap" "$d"
    run_quiet sgdisk -n3:0:0 -t3:BF01 -c3:"ZFS" "$d"
  done
  run_quiet partprobe "$d1"; run_quiet partprobe "$d2"; sleep 1
  say_ok "Partitions created on both disks"
  echo
}

# ---------------------------
# FS creation (EFI / SWAP / ZFS)
# ---------------------------

require_cmd() { command -v "$1" >/dev/null 2>&1 || { say_fail "Missing tool: $1"; exit 1; }; }

mk_efi_vfat() {
  local dev="$1"
  log_info "[EFI: mkfs.vfat on ${dev}]"
  mkfs.vfat -F32 -n EFI "$dev" >/dev/null
  log_ok "EFI formatted (vfat, label=EFI)"
}

mk_swap_part() {
  local dev="$1" tag="$2"
  info "[SWAP: ${tag} -> ${dev}]"
  mkswap -L "swap_${tag}" "$dev" >/dev/null
  say_ok "Swap prepared (${tag})"
}

zfs_pool_create_single() {
  local dev="$1"
  info "[ZFS: single-disk pool 'rpool' on ${dev}]"
  zpool create -f \
    -o ashift=12 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O compression=zstd \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -O normalization=formD \
    -O mountpoint=none \
    rpool "$dev"
  say_ok "ZFS pool 'rpool' created (single)"
}

zfs_pool_create_mirror() {
  local dev1="$1" dev2="$2"
  info "[ZFS: mirror pool 'rpool' on ${dev1} + ${dev2}]"
  zpool create -f \
    -o ashift=12 \
    -o cachefile=/etc/zfs/zpool.cache \
    -O compression=zstd \
    -O atime=off \
    -O xattr=sa \
    -O acltype=posixacl \
    -O normalization=formD \
    -O mountpoint=none \
    rpool mirror "$dev1" "$dev2"
  say_ok "ZFS pool 'rpool' created (mirror)"
}

# Resolve /dev/mdX by mdadm array name via sysfs (reliable even if /dev/md/<name> symlink is missing)
md_dev_by_name() {
  local name="$1" b
  for b in /sys/block/md*; do
    [ -r "$b/md/array_name" ] || continue
    if [ "$(cat "$b/md/array_name")" = "$name" ]; then
      printf "/dev/%s" "$(basename "$b")"
      return 0
    fi
  done
  return 1
}

create_md_efi_raid() {
  local p1="$1" p2="$2" name="efi0"

  log_info "[EFI: creating mdadm RAID1 (metadata=1.0) name=${name}]"
  # Use array name; /dev/md/<name> symlink may not exist, so resolve below.
  mdadm --create "/dev/md/${name}" \
        --level=1 --raid-devices=2 --metadata=1.0 \
        --name="${name}" "$p1" "$p2" >/dev/null

  udevadm settle || true

  local mdnode=""
  if mdnode="$(md_dev_by_name "$name")"; then
    :
  elif [ -e "/dev/md/${name}" ]; then
    mdnode="/dev/md/${name}"
  fi

  if [ -z "$mdnode" ] || [ ! -e "$mdnode" ]; then
    log_fail "Could not resolve md device for name '${name}'."
    return 1
  fi

  log_ok "md RAID for EFI created at ${mdnode}"
  # Echo ONLY the path on stdout (so callers can capture it safely)
  echo "$mdnode"
}

fs_phase_single() {
  local efi zfs swap
  efi=$(partpath "$DISK1" 1)
  swap=$(partpath "$DISK1" 2)
  zfs=$(partpath "$DISK1" 3)

  mk_efi_vfat "$efi"
  mk_swap_part "$swap" "d1"
  zfs_pool_create_single "$zfs"
}

fs_phase_mirror() {
  local efi1 efi2 swap1 swap2 zfs1 zfs2 md_efi
  efi1=$(partpath "$DISK1" 1); efi2=$(partpath "$DISK2" 1)
  swap1=$(partpath "$DISK1" 2); swap2=$(partpath "$DISK2" 2)
  zfs1=$(partpath "$DISK1" 3);  zfs2=$(partpath "$DISK2" 3)

  md_efi="$(create_md_efi_raid "$efi1" "$efi2")" || exit 1
  mk_efi_vfat "$md_efi"

  # independent swaps (preferred; no RAID)
  mk_swap_part "$swap1" "d1"
  mk_swap_part "$swap2" "d2"

  zfs_pool_create_mirror "$zfs1" "$zfs2"
}

# ---------------------------
# Run FS phase
# ---------------------------
run_fs_phase() {
  info "[Preparing filesystems]"
  require_cmd mkfs.vfat
  require_cmd mdadm
  require_cmd zpool
  require_cmd mkswap
  require_cmd udevadm

  if [ "${MIRROR}" = "true" ]; then
    fs_phase_mirror
  else
    fs_phase_single
  fi

  echo
  say_ok "Filesystem phase complete"
}

# ---------------------------
# Input flow
# ---------------------------
gather_inputs() {
  MIRROR=""
  DISK1=""; DISK2=""
  SWAPSIZE=""
  VOID_HOSTNAME=""
  VOID_USER=""
  VOID_TIMEZONE=""
  VOID_KEYMAP=""

  header
  run_prechecks
  get_disk DISK1
  get_mirror_choice
  header
  info "[Swap]"
  get_swapsize
  header
  info "[Hostname]"
  get_hostname
  header
  info "[Sudo]"
  get_sudo_user
  header
  info "[Timezone]"
  get_timezone
  header
  info "[Keymap]"
  get_keymap

  header
}

# ---------------------------
# Main
# ---------------------------
HN="$(hostname || true)"
if [ "${HN}" != "hrmpf" ] && [ "${HN}" != "voidlinux" ]; then
  echo -e "${RED}Hostname '${HN}' not in allowed list. Exiting.${NC}"
  exit 1
fi

while true; do
  gather_inputs
  if confirm_menu; then rc=0; else rc=$?; fi
  case "$rc" in
    10) info "[Restarting configuration]"; continue ;;
    20) echo -e "${YELLOW}Exiting without making changes.${NC}"; exit 0 ;;
    0) break ;;
  esac
done

if [ "${MIRROR}" = "true" ]; then
  info "[Proceed: MIRROR partitioning]"
  partition_mirror
else
  info "[Proceed: SINGLE-DISK partitioning]"
  partition_single
fi

info "[Partitioning phase completed]"
echo
run_fs_phase

