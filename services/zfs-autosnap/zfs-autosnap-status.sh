#!/bin/sh

# this is a WIP and WILL change
# its not included in the installer rn

JOBS="/etc/zfs-autosnap/jobs.conf"
STATE="/var/lib/zfs-autosnap"

trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

fmt_rel() {
  # input: seconds
  s=$1
  [ "$s" -lt 0 ] && s=0
  d=$(( s/86400 )); s=$(( s%86400 ))
  h=$(( s/3600 )); s=$(( s%3600 ))
  m=$(( s/60 ));  s=$(( s%60 ))
  printf "%2dd %2dh %2dm %2ds" "$d" "$h" "$m" "$s"
}

next_midnight() {
  date -d "tomorrow 00:00" +%s
}

next_top_of_hour() {
  date -d "next hour" +%s
}

next_quarter() {
  now_ts=$(date +%s)
  H=$(date +%H)
  M=$(date +%M)
  q=$(( (M/15 + 1) * 15 ))
  if [ "$q" -ge 60 ]; then
    # wrap to next hour at :00
    date -d "today ${H}:00 +1 hour" +%s
  else
    printf "%s\n" "$(date -d "today ${H}:$(printf %02d "$q"):00" +%s)"
  fi
}

next_minute() {
  date -d "now +1 minute" +%s
}

compute_next_from_sched() {
  sched="$1"
  case "$sched" in
    *"-H0"*"-M0"*)     next_midnight ;;
    *"-H*"*"-M0"*)     next_top_of_hour ;;
    *"-H*"*"-M/15"*)   next_quarter ;;
    *"-H*"*"-M*"*)     next_minute ;;
    *)                 date -d "now +5 minutes" +%s ;;  # fallback
  esac
}

now_ts=$(date +%s)
echo "Now: $(date -Ins)"
printf "%-16s | %-19s | %s\n" "Job" "Last run (mtime)" "Next run (from NOW)"
echo "--------------------------------------------------------------------------"

grep -v '^[[:space:]]*\(#\|$\)' "$JOBS" |
while IFS='|' read -r name dataset label sched keep slack flags; do
  name=$(printf '%s' "$name" | trim)
  sched=$(printf '%s' "$sched" | trim)
  tf="$STATE/${name}.timefile"

  last="(none)"
  if [ -e "$tf" ]; then
    last="$(date -d "$(stat -c %y "$tf")" '+%F %T')"
  fi

  next_ts=$(compute_next_from_sched "$sched")
  rel=$(( next_ts - now_ts ))
  next_str="$(date -d "@$next_ts" +%Y-%m-%dT%H:%M:%S%z)"
  printf "%-16s | %-19s | %s  %s\n" "$name" "$last" "$next_str" "$(fmt_rel "$rel")"
done

