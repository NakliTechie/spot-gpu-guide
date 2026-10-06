#!/bin/bash
# VM startup script for a ONE-SHOT batch job (eval, sweep, data build) on a spot GPU. GUIDE.md §2.10, §3.
# Shape: restore a FIXED campaign path → resumable units → push every 90 s → DONE marker → self-delete.
# Run it under templates/relaunch.sh, never from a one-shot launcher (GUIDE §2.10).
# Generalised from a batch-eval startup script that survived a real preemption and resumed per unit.
#
# ======================== PLACEHOLDERS — edit these ========================
B="gs://<bucket>"
CAMPAIGN="<job-name>/campaign-1"       # FIXED per campaign, not per boot: a relaunch resumes from what is here
CODE="<bucket-path-to-repo.tgz>"       # git archive HEAD, uploaded by the launcher
UNITS="unit-a unit-b"                  # work units, in decision-metric-first order; each is resumable
# ===========================================================================
set -uo pipefail                                   # pipefail: a failing producer in a pipe must not read as success
export HOME=${HOME:-/root}
OUT=$B/$CAMPAIGN
LOG=/var/log/job.log; LOGNAME=job-$(date -u +%Y%m%dT%H%MZ).log   # per-life log; the campaign keeps every life's log
exec >>"$LOG" 2>&1                                 # file only: the script runner's 64 KB line limit (GUIDE §3)
MD=http://metadata.google.internal/computeMetadata/v1/instance
Z=$(curl -sf -H "Metadata-Flavor: Google" $MD/zone | awk -F/ '{print $NF}')
SELF=$(hostname); readonly SELF                    # readonly: a loop variable once shadowed a name like this, and the trap deletes $SELF
push(){ gcloud storage cp -q "$LOG" "$OUT/$LOGNAME" 2>/dev/null
        [ -d /opt/job/runs ] && gcloud storage rsync -q -r /opt/job/runs "$OUT/runs" 2>/dev/null; }   # never a delete flag (GUIDE §2.8)
finish(){ rc=$?; echo "JOB finish $(date -u +%H:%M:%SZ) rc=$rc"; push
          pre=$(curl -sf -H "Metadata-Flavor: Google" $MD/preempted)
          # Explicit failure only: a preemption (or the SIGTERM/SIGKILL it sends) must not stop the launcher for good.
          if [ $rc -ne 0 ] && [ "$pre" != TRUE ] && [ $rc -ne 130 ] && [ $rc -ne 137 ] && [ $rc -ne 143 ]; then
            echo "rc=$rc $(date -u)" | gcloud storage cp - "$OUT/ERROR"; fi
          gcloud compute instances delete "$SELF" --zone "$Z" --quiet; }
trap finish EXIT
# After the trap: an unfilled placeholder then writes ERROR and the VM deletes itself instead of billing to its cap.
grep -q "^[A-Z_]*=\"[^\"]*<[a-z]" "$0" && { echo "fill the placeholders at the top of $0 first"; exit 1; }
( while sleep 90; do push; done ) &

echo "JOB boot $(date -u +%H:%M:%SZ) zone=$Z $(nvidia-smi --query-gpu=name --format=csv,noheader)"
mkdir -p /opt/job && cd /opt/job && gcloud storage cp -q "$B/$CODE" repo.tgz && tar xzf repo.tgz && mkdir -p runs data inputs
gcloud storage rsync -q -r "$OUT/runs" runs 2>/dev/null       # resume: the runner must skip units recorded here
echo "JOB resume: $(find runs -type f | wc -l) files restored"
# ---- data + deps: fill in (gcloud storage rsync -r $B/data data; uv sync; apt-get install -y g++ for JIT builds) ----

# ---- inputs copied per item ----
# mkdir -p FIRST: `gcloud storage cp` refuses a destination directory that does not exist (wildcards too).
# Never send a gating step's stderr to /dev/null: five silent copy failures cost a whole VM life (GUIDE §3).
# for S in ...; do mkdir -p inputs/$S; gcloud storage cp "$B/.../$S/*" inputs/$S/ 2>&1 | grep -i error; done

# ---- ready line + gate: one greppable line tier 1 reads 5–8 min after launch (GUIDE §3, §4.3) ----
READY="<what the job is about to run: models served, adapters exported, task counts>"
echo "JOB ready $READY"
# [ -n "$INPUTS" ] || { echo "JOB abort: inputs missing"; exit 0; }   # exit 0: not an ERROR, but do not run a no-op life

# ---- the work: each unit appends (>>) to runs/<unit>.log and skips items already in runs/<unit>.jsonl ----
run(){ echo "JOB start $1 $(date -u +%H:%M:%SZ)"
       # python -m <your.runner> --tag "$1" ... >> "runs/$1.log" 2>&1 || exit 1
       echo "JOB $1 $(date -u +%H:%M:%SZ) $(grep -m1 METRIC "runs/$1.log" 2>/dev/null)"; push; }
for U in $UNITS; do run "$U"; done

echo "JOB done $(date -u +%H:%M:%SZ)"
date -u | gcloud storage cp - "$OUT/DONE"           # the relaunch loop stops on this marker
