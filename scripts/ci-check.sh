#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
	cat <<EOF
Usage: $0 [--unit] [--vm single|mirror]

Default:
  $0 --unit
EOF
}

run_unit=false
vm_mode=""

if [[ $# -eq 0 ]]; then
	run_unit=true
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
	--unit)
		run_unit=true
		shift
		;;
	--vm)
		vm_mode="${2:?--vm requires 'single' or 'mirror'}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
done

if [[ "$run_unit" == true ]]; then
	tests/unit/run.sh
fi

if [[ -n "$vm_mode" ]]; then
	tests/vm/run.sh "$vm_mode"
fi
