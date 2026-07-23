#!/usr/bin/env bash
set -Eeuo pipefail

MODE="${1:-}"
if [[ "$MODE" != "single" && "$MODE" != "mirror" ]]; then
	printf "usage: %s single|mirror\n" "$0" >&2
	exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts/vm-$MODE}"
CACHE_DIR="${CACHE_DIR:-$ROOT_DIR/.cache/vm}"
mkdir -p "$ARTIFACT_DIR" "$CACHE_DIR"

ISO_PATH="${HRMPF_ISO_PATH:-}"
ISO_URL="${HRMPF_ISO_URL:-}"
ISO_SHA256="${HRMPF_ISO_SHA256:-}"
SSH_PORT="${SSH_PORT:-2222}"
VM_MEM="${VM_MEM:-4096}"
VM_CPUS="${VM_CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-16G}"
INSTALL_TIMEOUT="${INSTALL_TIMEOUT:-7200}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-900}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE.fd}"

require() {
	command -v "$1" >/dev/null 2>&1 || {
		printf "missing required command: %s\n" "$1" >&2
		exit 1
	}
}

require "$QEMU_BIN"
require qemu-img
require curl
require ssh
require scp
require sshpass
require tar

resolve_latest_hrmpf() {
	local api release asset
	api="${HRMPF_RELEASE_API:-https://api.github.com/repos/leahneukirchen/hrmpf/releases/latest}"
	release="$(curl -fsSL "$api")"
	asset="$(grep -Eo '"browser_download_url":[[:space:]]*"[^"]*hrmpf-x86_64-[0-9]+\.iso"' <<<"$release" | head -n1 | sed -E 's/.*"([^"]+)"/\1/')"
	[[ -n "$asset" ]] || {
		printf "could not resolve latest hrmpf x86_64 ISO from %s\n" "$api" >&2
		exit 1
	}
	ISO_URL="$asset"
	ISO_SHA256="$(grep -Eo 'SHA256 \(hrmpf-x86_64-[0-9]+\.iso\) = [0-9a-f]+' <<<"$release" | head -n1 | awk '{ print $4 }')"
}

download_iso() {
	if [[ -n "$ISO_PATH" ]]; then
		return 0
	fi
	if [[ -z "$ISO_URL" ]]; then
		resolve_latest_hrmpf
	fi

	ISO_PATH="$CACHE_DIR/${ISO_URL##*/}"
	if [[ ! -s "$ISO_PATH" ]]; then
		curl -fL "$ISO_URL" -o "$ISO_PATH"
	fi
	if [[ -n "$ISO_SHA256" ]]; then
		printf "%s  %s\n" "$ISO_SHA256" "$ISO_PATH" | sha256sum -c -
	fi
	printf "ISO_URL=%s\nISO_PATH=%s\nISO_SHA256=%s\n" "$ISO_URL" "$ISO_PATH" "$ISO_SHA256" | tee "$ARTIFACT_DIR/image.env"
}

qemu_args_base() {
	local ovmf_vars="$ARTIFACT_DIR/OVMF_VARS.fd"
	cp /usr/share/OVMF/OVMF_VARS.fd "$ovmf_vars"
	if [[ -r /dev/kvm && -w /dev/kvm ]]; then
		printf '%s\0' -enable-kvm -machine q35,accel=kvm:tcg
	else
		printf '%s\0' -machine q35,accel=tcg
	fi
	printf '%s\0' \
		-m "$VM_MEM" \
		-smp "$VM_CPUS" \
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$ovmf_vars" \
		-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
		-device virtio-net-pci,netdev=net0 \
		-nographic
}

start_guest() {
	local phase="$1"
	shift
	local log="$ARTIFACT_DIR/qemu-$phase.log"
	"$QEMU_BIN" "$@" >"$log" 2>&1 &
	QEMU_PID=$!
	printf "%s\n" "$QEMU_PID" >"$ARTIFACT_DIR/qemu-$phase.pid"
}

stop_guest() {
	if [[ -n "${QEMU_PID:-}" ]] && kill -0 "$QEMU_PID" 2>/dev/null; then
		kill "$QEMU_PID" 2>/dev/null || true
		wait "$QEMU_PID" 2>/dev/null || true
	fi
}
trap stop_guest EXIT

ssh_opts=(
	-o StrictHostKeyChecking=no
	-o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR
	-p "$SSH_PORT"
)

wait_for_ssh() {
	local deadline=$((SECONDS + BOOT_TIMEOUT))
	while (( SECONDS < deadline )); do
		if sshpass -p voidlinux ssh "${ssh_opts[@]}" root@127.0.0.1 true 2>/dev/null; then
			SSH_USER=root
			return 0
		fi
		if sshpass -p voidlinux ssh "${ssh_opts[@]}" anon@127.0.0.1 true 2>/dev/null; then
			SSH_USER=anon
			return 0
		fi
		sleep 5
	done
	printf "guest did not become reachable over SSH\n" >&2
	return 1
}

guest() {
	local cmd="$1"
	local timeout_args=()
	if [[ -n "${GUEST_TIMEOUT:-}" ]]; then
		timeout_args=(timeout "$GUEST_TIMEOUT")
	fi

	if [[ "${SSH_USER:-}" == root ]]; then
		"${timeout_args[@]}" sshpass -p voidlinux ssh "${ssh_opts[@]}" root@127.0.0.1 "$cmd"
	else
		local remote_script="/home/anon/voidzfs-command-${RANDOM}.sh"
		local local_script="$ARTIFACT_DIR/remote-command-${RANDOM}.sh"
		printf "%s\n" "$cmd" >"$local_script"
		sshpass -p voidlinux scp "${ssh_opts[@]}" "$local_script" anon@127.0.0.1:"$remote_script"
		"${timeout_args[@]}" sshpass -p voidlinux ssh -tt "${ssh_opts[@]}" anon@127.0.0.1 "printf '%s\n' voidlinux | su -c 'sh $remote_script'"
	fi
}

guest_copy_repo() {
	local tarball="$ARTIFACT_DIR/repo.tar"
	tar -C "$ROOT_DIR" \
		--exclude=.git \
		--exclude=.cache \
		--exclude=artifacts \
		-cf "$tarball" .
	if [[ "${SSH_USER:-}" == root ]]; then
		sshpass -p voidlinux scp "${ssh_opts[@]}" "$tarball" root@127.0.0.1:/tmp/repo.tar
	else
		sshpass -p voidlinux scp "${ssh_opts[@]}" "$tarball" anon@127.0.0.1:/home/anon/repo.tar
		guest "cp /home/anon/repo.tar /tmp/repo.tar"
	fi
	guest "rm -rf /root/voidzfs-install && mkdir -p /root/voidzfs-install && tar -xf /tmp/repo.tar -C /root/voidzfs-install"
}

make_disks() {
	qemu-img create -f qcow2 "$ARTIFACT_DIR/disk1.qcow2" "$DISK_SIZE"
	if [[ "$MODE" == mirror ]]; then
		qemu-img create -f qcow2 "$ARTIFACT_DIR/disk2.qcow2" "$DISK_SIZE"
	fi
}

install_guest() {
	local mirror disk2_env install_cmd
	mirror=false
	disk2_env=""
	if [[ "$MODE" == mirror ]]; then
		mirror=true
		disk2_env="VOID_DISK2=/dev/vdb"
	fi

	install_cmd="cd /root/voidzfs-install && env VOID_CHECK_HOSTNAME=false VOID_MIRROR=$mirror VOID_DISK1=/dev/vda $disk2_env VOID_SWAPSIZE=1 VOID_HOSTNAME=voidlinux VOID_SUDOUSER=ci VOID_TIMEZONE=Europe/Vienna VOID_KEYMAP=us VOID_USER_PASSWORD=voidlinux VOID_ZFS_PASSPHRASE=voidlinux bash install.sh --non-interactive"
	GUEST_TIMEOUT="$INSTALL_TIMEOUT" guest "$install_cmd" 2>&1 | tee "$ARTIFACT_DIR/install.log"
}

verify_guest() {
	local script
	script='
set -eu
mkdir -p /tmp/voidzfs-verify-key /mnt
printf "%s\n" voidlinux >/tmp/voidzfs-verify-key/zroot.key
chmod 000 /tmp/voidzfs-verify-key/zroot.key
zpool import -N -R /mnt zroot
zfs load-key -L file:///tmp/voidzfs-verify-key/zroot.key zroot
zfs mount zroot/ROOT/void
zfs mount zroot/home
mkdir -p /mnt/boot/efi
mount /dev/vda1 /mnt/boot/efi
if [ "'"$MODE"'" = mirror ]; then
  mkdir -p /mnt/boot/efi2
  mount /dev/vdb1 /mnt/boot/efi2
fi
zpool status zroot
zfs list zroot/ROOT/void
zfs list zroot/home
test "$(zpool get -H -o value bootfs zroot)" = "zroot/ROOT/void"
test "$(cat /mnt/etc/hostname)" = "voidlinux"
chroot /mnt id ci
chroot /mnt sh -c "id -nG ci | grep -qw wheel"
test -f /mnt/boot/efi/EFI/zbm/vmlinuz.EFI
test -f /mnt/boot/efi/EFI/BOOT/BOOTX64.EFI
grep -q "/boot/efi" /mnt/etc/fstab
grep -q " swap " /mnt/etc/fstab
test -x /mnt/etc/sv/zfs-autosnap/run
test -x /mnt/etc/sv/zfs-autosnap/log/run
test -x /mnt/usr/local/bin/zfs-autosnap.sh
if [ "'"$MODE"'" = mirror ]; then
  grep -q "/boot/efi2" /mnt/etc/fstab
  test -x /mnt/etc/sv/efisync/run
  test -x /mnt/etc/sv/efisync/log/run
  test -x /mnt/usr/local/bin/efisync.sh
else
  test ! -e /mnt/etc/sv/efisync
fi
umount -R /mnt
zpool export zroot
'
	guest "$script" 2>&1 | tee "$ARTIFACT_DIR/verify.log"
}

download_iso
make_disks

args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(qemu_args_base)
args+=(
	-boot d
	-cdrom "$ISO_PATH"
	-drive "file=$ARTIFACT_DIR/disk1.qcow2,if=virtio,format=qcow2"
)
if [[ "$MODE" == mirror ]]; then
	args+=(-drive "file=$ARTIFACT_DIR/disk2.qcow2,if=virtio,format=qcow2")
fi

start_guest "install" "${args[@]}"
wait_for_ssh
guest_copy_repo
install_guest
verify_guest
guest "poweroff -f" || true
stop_guest

printf "vm %s test passed\n" "$MODE"
