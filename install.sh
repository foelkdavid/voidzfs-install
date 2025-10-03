#!/usr/bin/env bash

# prevents nuking the wrong system in most cases
# (allowed hostnames are hrmpf and voidlinux)
# set this to false at your own risk ;)
VOID_CHECK_HOSTNAME=true


set -Eeo pipefail


# Define Colors for prettier printing
R="\033[0;31m" # Red
G="\033[0;32m" # Green
B="\033[0;34m" # Blue
Y="\033[0;33m" # Yellow
P="\033[0;35m" # Purple
LG="\033[1;32m" # Light Green
LB="\033[1;34m" # Light Blue
NC="\033[0m"


# helpers for prettier printing
ok() { printf "  %b %s\n" "${G}✔${NC}" "$1"; }
fail() { printf "  %b %s\n" "${R}✘${NC}" "$1"; }
failhard() { printf "  %b\n" "${R}✘ $1${NC}"; }
info() { printf "%b%s%b\n" "$P" "$1" "$NC"; }


# used in run_prechecks()
check() {
    local desc="$1"; shift
    if [ "$1" = "hostnamecheck" ]; then
        if "$@"; then
            ok "$desc"
        else
            # hostnamecheck already printed failhard
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
        return 0  # check disabled
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

run_prechecks() {
    clear
    echo "──────────────────────"
    echo -e "${G}Void-ZFS-Installer${NC}"
    echo "──────────────────────"
    FAILED=0
    info "[Running Pre-Checks]"
    check "System booted in EFI mode" test -d /sys/firmware/efi
    check "Connectivity to 1.1.1.1 (ICMP)" ping -c2 -W2 1.1.1.1
    check "DNS resolution (voidlinux.org)" ping -c2 -W2 voidlinux.org
    check "Check hostname" hostnamecheck

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
    disklist="$(lsblk -ndp | awk '{printf "  %-15s %s\n", $1, $4}')"
    echo -e "${LB}${disklist}${NC}"
    echo "──────────────────────"

    while true; do
        read -rp "Enter the full path of the disk you want to use: " chosen_disk

        if ! lsblk -dpno NAME | grep -qx "$chosen_disk"; then
            failhard "Invalid disk path: ${chosen_disk}"
        elif [[ $chosen_disk == "${VOID_DISK1:-}" ]]; then
            failhard "You already selected this disk: ${chosen_disk}${NC}"
        else
            disk_var="VOID_DISK1"
            size_var="VOID_DISK1_SIZE"
            [[ -n "${VOID_DISK1:-}" ]] && disk_var="VOID_DISK2"
            [[ -n "${VOID_DISK1:-}" ]] && size_var="VOID_DISK2_SIZE"
            printf -v "$disk_var" "%s" "$chosen_disk"
            read -r disk_size < <(lsblk -dnpo SIZE "$chosen_disk") # This cleans whitespaces (lsblk output can differ greatly)
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
            y|yes) VOID_MIRROR=true && print_preconf_header && get_disks; break ;;
            n|no)  VOID_MIRROR=false; VOID_DISK2=none || true; echo; break ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}


get_swapsize() {
    info "[Swap Configuration]"
    echo -e "  ${B}If you use a mirror, swap will be partitioned on both disks.${NC}"
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
    echo -e "  ${B}Validity will be checked automatically..${NC}"
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
    echo -e "  ${B}Your desired username, probably..${NC}"
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
    echo -e "  ${B}Located at /usr/share/zoneinfo* ${NC}"
    echo -e "  ${B}e.g. Europe/Vienna${NC}"
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
    echo -e "  ${B}e.g. de, de-latin1, us, ...${NC}"
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
    echo -e "  ${B}What do you want to do?${NC}"
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
disk_partitioning() {

  # Check if disk 2 exists
  local disks=("$VOID_DISK1")
  [[ "${VOID_MIRROR:-false}" == true && -n "${VOID_DISK2:-}" && "$VOID_DISK2" != "none" ]] && disks+=("$VOID_DISK2")

  # partition disk(s)
  for d in "${disks[@]}"; do
    info "[Partitioning $d]"
    sgdisk --zap-all "$d" >/dev/null || { failhard "Wipe failed: $d"; exit 1; }
    sgdisk \
      -n1:1MiB:+512MiB  -t1:ef00 -c1:EFI \
      -n2:0:+${VOID_SWAPSIZE}GiB -t2:8200 -c2:swap \
      -n3:0:-10MiB      -t3:bf00 -c3:zfs \
      "$d" >/dev/null || { failhard "sgdisk failed on $d"; exit 1; }
    partprobe "$d" >/dev/null 2>&1 || true
    ok "Created EFI/swap/ZFS on $d"
  done
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
