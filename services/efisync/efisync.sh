#!/usr/bin/env bash
set -Eeuo pipefail

do_sync() {
  # Optional mount guards are enabled for BIOS mirrors. A missing boot disk
  # must not turn an empty directory into the source of a destructive sync.
  local boot_mount
  for boot_mount in "${SRC_MOUNT:-}" "${DST_MOUNT:-}"; do
    if [[ -n "$boot_mount" ]] && ! mountpoint -q "$boot_mount"; then
      echo "Error: boot filesystem is not mounted: $boot_mount" >&2
      return 1
    fi
  done
  printf "[%(%F %T)T] syncing...\n" -1
  flock "$LOCK" rsync -av --delete -- "$SRC"/ "$DST"/
  printf "[%(%F %T)T] sync done.\n" -1
}

efisync_main() {
  # only try to do it as root (in case you want to run it manually)
  if [[ $EUID -ne 0 ]]; then
    echo "Error: must be run as root." >&2
    exit 1
  fi

  # check if commands are available
  local REQUIRED=(rsync inotifywait flock)
  if [[ -n "${SRC_MOUNT:-}${DST_MOUNT:-}" ]]; then
    REQUIRED+=(mountpoint)
  fi
  local bin
  for bin in "${REQUIRED[@]}"; do
    command -v "$bin" >/dev/null 2>&1 || { echo "Error: missing '$bin'." >&2; exit 1; }
  done

  # defaults (you can overwrite these in the conf file of the runit-service)
  : "${SRC:=/boot/efi}"
  : "${DST:=/boot/efi2}"
  : "${LOCK:=/tmp/efisync.lock}"

  do_sync

  while inotifywait -qq -r -e close_write,create,delete,move,attrib -- "$SRC"; do
    while inotifywait -qq -r -t 1 -e close_write,create,delete,move,attrib -- "$SRC"; do :; done
    do_sync
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  efisync_main "$@"
fi
