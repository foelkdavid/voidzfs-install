#!/bin/sh
set -eu

JOBS="/etc/zfs-autosnap/jobs.conf"
STATE="/var/lib/zfs-autosnap"
mkdir -p "$STATE"

echo "[INFO] zfs-autosnap starting at $(date)"

# --- graceful cleanup for term/hup/int ---
cleanup() {
  echo "[INFO] zfs-autosnap shutting down, killing process group..."
  # Kill our whole process group
  kill -TERM -- -$$ 2>/dev/null || true
  pkill -TERM -P $$ 2>/dev/null || true
}
trap cleanup INT TERM HUP

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
expand_label() { printf '%s' "$1" | sed 's/\$(%/$(date +%/g'; }

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
  [ -e "$tf" ] || : > "$tf"

  rflag=""; printf '%s' "$flags" | grep -q 'r' && rflag="-r"

  prefix="${label%%\$\(*}"
  leval=$(expand_label "$label")

  echo "[INFO] worker '$name' -> dataset=$dataset schedule='$sched' keep=$keep slack=$slack flags=$flags"

  (
    trap 'exit 0' INT TERM HUP
    while :; do
      echo "[INFO] $name waiting (snooze $sched -s $slack -T $slack)"
      snooze $sched -s "$slack" -T "$slack" -t "$tf" sh -c '
        SNAP="'"$dataset"'@'$(eval echo "$leval")'"
        echo "[INFO] '"$name"' snapshot $SNAP"
        if zfs snapshot '"$rflag"' "$SNAP"; then
          touch "'"$tf"'"
        fi
        echo "[INFO] '"$name"' prune keep='"$keep"'"
        zfs list -H -t snapshot -o name -S creation \
          | grep "^'"$dataset"'@'"$prefix"'" \
          | tail -n +'"$((keep+1))"' \
          | xargs -r -n1 zfs destroy
        echo "[INFO] '"$name"' cycle done"
      '
    done
  ) &
done < "$JOBS"

wait
