#!/bin/bash
# Keep ONE spot VM alive for a one-shot job until its DONE (or ERROR) marker appears. GUIDE.md §2.4, §2.10.
# Usage: templates/relaunch.sh <job.env> [--once] [--dry-run]     (config: templates/job.env.example)
# Run it as a launchd agent (templates/launcher.plist) so it survives a reboot. Deliberate exits return 0, so
# KeepAlive{SuccessfulExit:false} restarts only crashes. Never `set -e`: one flaky gcloud call must not kill the loop.
# Differs from run_tier.sh: no tiers, no code upload, env-file config, zone rotation state, per-VM-name spend.
# Generalised from a relaunch loop that ran a multi-hour batch eval under launchd.
set -u
ENV=${1:?usage: relaunch.sh <job.env> [--once] [--dry-run]}; shift; ONCE=0; DRY=0
for a in "$@"; do case $a in --once) ONCE=1;; --dry-run) DRY=1;; esac; done
grep -q "<[a-z]" "$ENV" && { echo "fill the placeholders in $ENV first"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
# The startup script runs on the VM, where a placeholder exit would leave a GPU billing: check it here.
grep -q '^[A-Z_]*="[^"]*<[a-z]' "$JOB_STARTUP" && { echo "fill the placeholders in $JOB_STARTUP first"; exit 1; }
: "${JOB_MAX_LIVES:=6}" "${JOB_POLL:=60}" "${JOB_ERROR_CMD:=false}"
mkdir -p "$JOB_OUT"; STATE=$JOB_OUT/$JOB_NAME-relaunch.json; echo $$ > "$JOB_OUT/$JOB_NAME-relaunch.pid"
log(){ echo "$(date '+%F %H:%M') $*"; }   # local time
alert(){ log "ALERT $*"; command -v osascript >/dev/null && osascript -e "display notification \"${*//\"/\'}\" with title \"relaunch: $JOB_NAME\"" 2>/dev/null
         [ -n "${NTFY_TOPIC:-}" ] && curl -fsS -m 10 -d "relaunch[$JOB_NAME]: $*" "ntfy.sh/$NTFY_TOPIC" >/dev/null 2>&1; }
launches=$(python3 -c "import json;print(json.load(open('$STATE')).get('launches',0))" 2>/dev/null || echo 0)
read -r -a zones <<< "$JOB_ZONES"; zi=0
vm(){ gcloud compute instances list --project "$JOB_PROJECT" --filter="name=$JOB_NAME" --format='value(name,zone.basename(),status)' 2>/dev/null || echo "__LIST_FAILED__"; }
spent(){ # finished lives of THIS VM name from the operations log × rate, plus the running life's elapsed time
  gcloud compute operations list --project "$JOB_PROJECT" --format=json \
    --filter="operationType:(insert OR delete OR compute.instances.preempted) AND targetLink~instances/$JOB_NAME\$" 2>/dev/null |
  python3 -c "
import sys, json, datetime as dt
ops = sorted(json.load(sys.stdin), key=lambda o: o['insertTime']); open_ = None; h = 0.0
for o in ops:
    t = dt.datetime.fromisoformat(o.get('endTime') or o['insertTime'])
    if o['operationType'] == 'insert' and not o.get('error'): open_ = t
    elif open_ is not None: h += (t - open_).total_seconds() / 3600; open_ = None
if open_ is not None: h += (dt.datetime.now(dt.timezone.utc) - open_).total_seconds() / 3600
print(f'{h * float(\"$JOB_RATE\"):.2f}')" 2>/dev/null || echo UNKNOWN; }   # unknown spend is not zero spend
while true; do
  if eval "$JOB_DONE_CMD" >/dev/null 2>&1; then alert "DONE after $launches launches; exiting"; exit 0; fi
  if eval "$JOB_ERROR_CMD" >/dev/null 2>&1; then alert "ERROR marker present; not relaunching"; exit 0; fi
  v=$(vm); [ "$v" = "__LIST_FAILED__" ] && { log "instance list failed; skipping this round (a failed listing is not an empty one)"; sleep "$JOB_POLL"; continue; }
  usd=$(spent); [ "$usd" = UNKNOWN ] && { alert "spend lookup failed; launching nothing this round"; sleep "$JOB_POLL"; continue; }
  if python3 -c "import sys; sys.exit(0 if float('$usd') >= float('$JOB_CAP_USD') else 1)"; then
    alert "spend \$$usd ≥ cap \$$JOB_CAP_USD: deleting VM and stopping"
    read -r n z _ <<< "$v"; [ -n "${n:-}" ] && gcloud compute instances delete "$n" --project "$JOB_PROJECT" --zone "$z" --quiet >/dev/null 2>&1
    exit 0
  fi
  if [ -n "$v" ]; then log "status vm=$(echo "$v" | tr '\t' ' ') spend=\$$usd launches=$launches"
  else
    if [ "$launches" -ge "$JOB_MAX_LIVES" ]; then alert "$launches lives without DONE; stopping (raise JOB_MAX_LIVES to continue)"; exit 0; fi
    ok=0
    for ((i = 0; i < ${#zones[@]}; i++)); do z=${zones[$(( (zi + i) % ${#zones[@]} ))]}
      cmd=(gcloud compute instances create "$JOB_NAME" --project "$JOB_PROJECT" --zone "$z" --machine-type "$JOB_MACHINE"
           --provisioning-model SPOT --instance-termination-action DELETE --max-run-duration "$JOB_MAX_RUN"
           --image-family "$JOB_IMAGE_FAMILY" --image-project "$JOB_IMAGE_PROJECT" --boot-disk-type "$JOB_DISK_TYPE"
           --boot-disk-size "${JOB_DISK_GB}GB" --scopes cloud-platform --labels "$JOB_LABEL"
           --metadata-from-file "startup-script=$JOB_STARTUP")
      if [ "$DRY" = 1 ]; then log "DRY would run: ${cmd[*]}"; ok=1; break; fi
      if "${cmd[@]}" >/dev/null 2>"$JOB_OUT/$JOB_NAME-create.err"; then
        launches=$((launches + 1)); zi=$(( (zi + i) % ${#zones[@]} )); ok=1
        echo "{\"launches\": $launches, \"last_zone\": \"$z\", \"at\": \"$(date -u +%FT%TZ)\"}" > "$STATE"
        alert "launched $JOB_NAME life $launches in $z (cap $JOB_MAX_RUN, spend so far \$$usd)"; break
      elif grep -q -E 'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA[A-Z_]*|[A-Z_]*_EXCEEDED' "$JOB_OUT/$JOB_NAME-create.err"; then
        log "  $z: $(grep -m1 -o -E 'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA[A-Z_]*|[A-Z_]*_EXCEEDED' "$JOB_OUT/$JOB_NAME-create.err")"
      else  # not a capacity error: re-list next round before any retry, or the next zone gets a twin (GUIDE §2.4)
        log "  $z: $(head -c 200 "$JOB_OUT/$JOB_NAME-create.err"); re-listing before any retry"; break
      fi
    done
    [ "$ok" = 1 ] || log "no zone accepted; retry in $JOB_POLL s"
  fi
  [ "$ONCE" = 1 ] && exit 0
  sleep "$JOB_POLL"
done
