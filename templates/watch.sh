#!/bin/bash
# Stream a tier's launcher log plus milestone/error lines from the newest VM job log in the bucket.
# Usage: templates/watch.sh TIER   (a Monitor source; one line per event)
#
# ======================== PLACEHOLDERS — edit these ========================
GCLOUD_CONFIG="<gcloud-config>"
B="gs://<bucket>"
# Lines worth surfacing from the job log. Keep errors; add your own step/metric lines.
PATTERN='^==|Traceback|Error|error|failed|FAIL|PASS|resumed|Killed|unbound|No such|<your-step-metric-regex>'
# ===========================================================================
grep -q "^[A-Z_]*=\"[^\"]*<[a-z]" "$0" && { echo "fill the placeholders at the top of $0 first"; exit 1; }
cd "$(dirname "$0")/.." || exit 1; export CLOUDSDK_ACTIVE_CONFIG_NAME=$GCLOUD_CONFIG; T=$1
tmp=$(mktemp); first=1
tail -n 0 -F "logs/run_tier$T.log" 2>/dev/null | grep --line-buffered -v "^\.*$" &
seen=0; cur=""
while true; do
  f=$(gcloud storage ls "$B/logs/tier$T/" 2>/dev/null | sort | tail -1)
  if [ -n "$f" ]; then
    [ "$f" != "$cur" ] && { cur=$f; seen=0; }
    gcloud storage cat "$f" > "$tmp" 2>/dev/null || true
    n=$(wc -l < "$tmp")
    # First read of an already-running job: start from its current end (emit only new lines).
    # A follower that skips job logs older than itself goes silent; start from the log's current end.
    [ $first = 1 ] && { seen=$n; first=0; }
    if [ "$n" -gt "$seen" ]; then
      tail -n +$((seen + 1)) "$tmp" | grep -E "$PATTERN" | cut -c1-320
      seen=$n
    fi
  fi
  first=0
  sleep 60
done
