#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=/dev/null
source "$ROOT_DIR/install.sh"

failures=0

assert_ok() {
	local name="$1"
	shift
	if "$@"; then
		printf "ok - %s\n" "$name"
	else
		printf "not ok - %s\n" "$name" >&2
		failures=$((failures + 1))
	fi
}

assert_fail() {
	local name="$1"
	shift
	if "$@"; then
		printf "not ok - %s\n" "$name" >&2
		failures=$((failures + 1))
	else
		printf "ok - %s\n" "$name"
	fi
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		printf "ok - %s\n" "$name"
	else
		printf "not ok - %s: expected '%s', got '%s'\n" "$name" "$expected" "$actual" >&2
		failures=$((failures + 1))
	fi
}

assert_ok "valid simple hostname" validate_hostname "voidlinux"
assert_ok "valid fqdn hostname" validate_hostname "build-01.example.org"
assert_fail "reject leading hyphen hostname" validate_hostname "-void"
assert_fail "reject trailing hyphen hostname" validate_hostname "void-"
assert_fail "reject underscore hostname" validate_hostname "void_linux"

assert_ok "valid username" validate_username "david"
assert_ok "valid underscore username" validate_username "_builder"
assert_fail "reject root username" validate_username "root"
assert_fail "reject uppercase username" validate_username "David"
assert_fail "reject too long username" validate_username "abcdefghijklmnopqrstuvwxyzabcdefg"

assert_eq "sata partition suffix" "/dev/sda3" "$(devpart /dev/sda 3)"
assert_eq "virtio partition suffix" "/dev/vda2" "$(devpart /dev/vda 2)"
assert_eq "nvme partition suffix" "/dev/nvme0n1p1" "$(devpart /dev/nvme0n1 1)"
assert_eq "mmc partition suffix" "/dev/mmcblk0p2" "$(devpart /dev/mmcblk0 2)"

assert_ok "required service files exist" servicecheck
assert_ok "localhost resolves" resolvecheck localhost

(
	timeout() {
		[[ "$1" == 10 && "$2" == bash && "$3" == -c && "$4" == ":</dev/tcp/example.org/443" ]]
	}
	tcpcheck example.org 443
)
status=$?
assert_ok "tcpcheck uses bash tcp socket with timeout" test "$status" -eq 0

while IFS= read -r line; do
	[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
	fields="$(awk -F'|' '{ print NF }' <<<"$line")"
	if [[ "$fields" != 7 ]]; then
		printf "not ok - jobs.conf row has %s fields: %s\n" "$fields" "$line" >&2
		failures=$((failures + 1))
	fi
done < services/zfs-autosnap/jobs.conf
printf "ok - jobs.conf rows are pipe-delimited\n"

(
	run_prechecks() { :; }
	validate_timezone() { [[ "$1" == "Europe/Vienna" ]]; }
	validate_keymap() { [[ "$1" == "us" ]]; }
	export VOID_MIRROR=false
	export VOID_DISK1=/dev/vda
	export VOID_SWAPSIZE=1
	export VOID_HOSTNAME=voidlinux
	export VOID_SUDOUSER=tester
	export VOID_TIMEZONE=Europe/Vienna
	export VOID_KEYMAP=us
	export VOID_USER_PASSWORD=testpass
	export VOID_ZFS_PASSPHRASE=testpassphrase
	configure_non_interactive_inputs >/dev/null
	[[ "$VOID_DISK2" == "none" && "$USER_PASSWORD" == "testpass" && "$ZFS_PASSPHRASE" == "testpassphrase" ]]
)
status=$?
assert_ok "non-interactive single disk config" test "$status" -eq 0

set +e
(
	run_prechecks() { :; }
	validate_timezone() { :; }
	validate_keymap() { :; }
	export VOID_MIRROR=true
	export VOID_DISK1=/dev/vda
	export VOID_DISK2=/dev/vda
	export VOID_SWAPSIZE=1
	export VOID_HOSTNAME=voidlinux
	export VOID_SUDOUSER=tester
	export VOID_TIMEZONE=Europe/Vienna
	export VOID_KEYMAP=us
	export VOID_USER_PASSWORD=testpass
	export VOID_ZFS_PASSPHRASE=testpassphrase
	configure_non_interactive_inputs >/dev/null
)
status=$?
set -e
assert_fail "non-interactive rejects duplicate mirror disks" test "$status" -eq 0

if (( failures > 0 )); then
	printf "%s unit test(s) failed\n" "$failures" >&2
	exit 1
fi

printf "unit tests passed\n"
