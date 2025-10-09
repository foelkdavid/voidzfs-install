#!/usr/bin/env bash
set -Eeuo pipefail

# only try to do it as root (in case you want to run it manually)
if [[ $EUID -ne 0 ]]; then
  echo "Error: must be run as root." >&2
  exit 1
fi

# check if commands are available
REQUIRED=(rsync inotifywait flock)
for bin in "${REQUIRED[@]}"; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Error: missing '$bin'." >&2; exit 1; }
done

# defaults (you can overwrite these in the conf file of the runit-service
: "${SRC:=/boot/efi}"
: "${DST:=/boot/efi2}"
: "${LOCK:=/tmp/efisync.lock}"

do_sync() {
  printf "[%(%F %T)T] syncing...\n" -1
  flock "$LOCK" rsync -av --delete -- "$SRC"/ "$DST"/
  printf "[%(%F %T)T] sync done.\n" -1
}

do_sync

while inotifywait -qq -r -e close_write,create,delete,move,attrib -- "$SRC"; do
  while inotifywait -qq -r -t 1 -e close_write,create,delete,move,attrib -- "$SRC"; do :; done
  do_sync
done
