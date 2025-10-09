#!/bin/sh

set -eu

JOBS="/etc/zfs-autosnap/jobs.conf"
STATE="/var/lib/zfs-autosnap"
mkdir -p "$STATE"

echo "[INFO] zfs-autosnap starting at $(date)"

# ────────────────────────────────────────────────────────────────
# graceful cleanup for term/hup/int
cleanup() {
  echo "[INFO] zfs-autosnap shutting down, killing process group..."
  kill -TERM -- -$$ 2>/dev/null || true
  pkill -TERM -P $$ 2>/dev/null || true
}
trap cleanup INT TERM HUP

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# ────────────────────────────────────────────────────────────────
# initialize timefile to previous valid boundary
init_timefile() {
  sched="$1"
  tf="$2"
  if [ ! -e "$tf" ]; then
    case "$sched" in
      *"-H0"*"-M0"*) ts="$(date -d 'today 00:00' +%s)";;
      *"-M0"*)       ts="$(date -d 'this hour' +%s)";;
      *"-M/15"*)     m=$(date +%M); q=$((m - (m%15))); ts="$(date -d "$(date +%F) $(date +%H):$q:00" +%s)";;
      *"-M*"*)       ts="$(date -d 'now - 1 minute' +%s)";;
      *)             ts="$(date -d 'now - 1 minute' +%s)";;
    esac
    touch -d "@$ts" "$tf"
  fi
}

# ────────────────────────────────────────────────────────────────
# main loop over jobs
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s' "$line" | grep -q '^[[:space:]]*#' && continue

  IFS='|' read -r name dataset label sched keep slack flags <<EOF
$line
EOF

  name=$(printf '%s' "$name" | trim)
  dataset=$(printf '%s' "$dataset" | trim)
  label=$(printf '%s' "$label" | trim)
  sched=$(printf '%s' "$sched" | trim)
  keep=$(printf '%s' "$keep" | trim)
  slack=$(printf '%s' "$slack" | trim)
  flags=$(printf '%s' "$flags" | trim)

  tf="$STATE/${name}.timefile"
  init_timefile "$sched" "$tf"

  rflag=""
  printf '%s' "$flags" | grep -q 'r' && rflag="-r"

  prefix="${label%%\$\(*}"                                 # part before $(date)
  lpatt="$(printf '%s' "$label" | sed -n "s/.*\$(\([^)]*\)).*/\1/p")"
  [ -n "$lpatt" ] || lpatt="%Y%m%d-%H%M"

  echo "[INFO] worker '$name' -> dataset=$dataset schedule='$sched' keep=$keep slack=$slack flags=$flags"

  (
    trap 'exit 0' INT TERM HUP
    while :; do
      echo "[INFO] $name waiting (snooze $sched -s $slack -T $slack)"

      TAIL_FROM=$((keep + 1))

      # export vars for use in subshell
      export SNAP_DATASET="$dataset"
      export SNAP_PREFIX="$prefix"
      export SNAP_LPATT="$lpatt"
      export TF="$tf"
      export KEEP="$keep"
      export TAIL_FROM="$TAIL_FROM"
      export RFLAG="$rflag"

      snooze $sched -s "$slack" -T "$slack" -t "$tf" sh -c '
        stamp=$(date +"$SNAP_LPATT")
        SNAP="$SNAP_DATASET@$SNAP_PREFIX$stamp"
        echo "[INFO] '"$name"' snapshot $SNAP"
        if zfs snapshot $RFLAG "$SNAP"; then
          touch "$TF"
        fi
        echo "[INFO] '"$name"' prune keep=$KEEP"
        zfs list -H -t snapshot -o name -S creation \
          | grep "^$SNAP_DATASET@$SNAP_PREFIX" \
          | tail -n +"$TAIL_FROM" \
          | xargs -r -n1 zfs destroy
        echo "[INFO] '"$name"' cycle done"
      '
    done
  ) &
done < "$JOBS"

wait

