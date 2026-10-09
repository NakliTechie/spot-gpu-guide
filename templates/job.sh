#!/bin/bash
# Runs on the GPU VM as its startup script. Every step is resumable; state lives in the bucket.
# Order: code -> env -> data -> train stages -> eval (decision metric first) -> gate. Then the VM deletes itself.
# Worked example: GCP (metadata server, gcloud storage).
#
# ======================== PLACEHOLDERS — edit these ========================
# Launcher passes these as instance metadata (see run_tier.sh): tier, bucket, eval_args.
STAGES="stage_a stage_b"              # <STAGES>: training scripts train_<stage>.py, run in order
PREP_CMD="prep_data.py --tier"        # <PREP_CMD>: your data prep entry point (gets the tier appended)
EVAL_TAGS="final baseline"            # <EVAL_TAGS>: eval order; put the go/no-go metric FIRST
PY_VERSION=3.12                       # <PY_VERSION>
# ===========================================================================
set -uo pipefail
export HOME=${HOME:-/root}  # startup scripts run as root with no HOME; `set -u` + $HOME would exit at once
MD=http://metadata.google.internal/computeMetadata/v1/instance
md() { curl -sf -H "Metadata-Flavor: Google" "$MD/$1"; }
TIER=$(md attributes/tier); B=$(md attributes/bucket); EVAL_ARGS=$(md attributes/eval_args || true)
NAME=$(md name); ZONE=$(md zone | awk -F/ '{print $NF}')
readonly NAME ZONE   # the exit trap deletes $NAME: nothing may reassign it (GUIDE §2.3)
W=/opt/work; mkdir -p $W && cd $W || exit 1
LOG=$W/job-$(date -u +%Y%m%dT%H%M%S).log
# Log to the file only. The GCE script runner reads stdout line by line (64 KB max). A tqdm bar redrawn with \r
# grows one "line" past that; the runner then stops reading and the job dies of SIGPIPE.
exec >>"$LOG" 2>&1
# Push the job log to the bucket every 2 min: the VM can vanish at any moment.
( while sleep 120; do gcloud storage cp -q "$LOG" "$B/logs/tier$TIER/" 2>/dev/null; done ) &
# Preemption notice (~30 s on GCP): flush the log, nothing bigger; checkpoints go up in the background (GUIDE §2.7).
( while :; do v=$(curl -sf -H "Metadata-Flavor: Google" "$MD/preempted?wait_for_change=true") || { sleep 5; continue; }
    [ "$v" = TRUE ] && { echo "== $(date -u) preemption notice"; gcloud storage cp -q "$LOG" "$B/logs/tier$TIER/"; break; }
  done ) &
R=$B/runs  # mirror root: <R>/tier<N>/<stage>
finish() {
  rc=$?
  # Explicit failure (not a preemption, not a first divergence rc=3) -> ERROR marker; the launcher stops on it.
  # Without it, a crash looks like a preemption and the launcher relaunches forever.
  # A preemption (or the SIGTERM/SIGKILL it sends, rc 130/137/143) is not a failure either.
  pre=$(md preempted)
  if [ $rc -ne 0 ] && [ $rc -ne 3 ] && [ "$pre" != TRUE ] && [ $rc -ne 130 ] && [ $rc -ne 137 ] && [ $rc -ne 143 ]; then echo "rc=$rc $(date -u)" | gcloud storage cp - "$R/tier$TIER/ERROR"; fi
  gcloud storage cp -q "$LOG" "$B/logs/tier$TIER/"
  gcloud compute instances delete "$NAME" --zone "$ZONE" --quiet   # self-delete: no idle GPU billing
}
trap finish EXIT

echo "== $(date -u) start tier $TIER on $NAME ($ZONE)"; nvidia-smi -L
# Code arrives as `git archive HEAD` from the launcher; the VM always runs a commit.
# A failed fetch or install is an explicit failure: exit 1 writes ERROR, so the launcher stops instead of relaunching.
gcloud storage cp -q "$B/code/code.tar.gz" . && tar xzf code.tar.gz || { echo "code fetch failed"; exit 1; }
curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null && export PATH=$HOME/.local/bin:$PATH
uv venv -q -p $PY_VERSION .venv && uv pip install -q --python .venv/bin/python -r requirements.txt \
  || { echo "dependency install failed"; exit 1; }
PY=.venv/bin/python
# PYTHONUNBUFFERED: pipe stdout is block-buffered; step logs otherwise appear an hour late.
# TQDM_DISABLE: see the 64 KB line limit above.
export TOKENIZERS_PARALLELISM=false PYTHONUNBUFFERED=1 TQDM_DISABLE=1

# ---- data: pull what the bucket has, build what it lacks, push it back ----
# Gated datasets: download on the laptop with your token, upload the raw file to $B/data/raw/. Never put the token on the VM.
mkdir -p data
gcloud storage rsync -q -r "$B/data/tier$TIER" data 2>/dev/null
gcloud storage cp -q "$B/data/raw/*" data/ 2>/dev/null
if [ ! -f data/DONE ]; then
  $PY $PREP_CMD "$TIER" --out data || { echo "data prep failed"; exit 1; }
  touch data/DONE; gcloud storage rsync -q -r data "$B/data/tier$TIER"
fi

# ---- training, with a divergence rule: one restart from the last checkpoint, then stop ----
# Each train_<stage>.py must: resume from $B checkpoints, skip itself when its DONE marker exists,
# and exit 3 on divergence.
mkdir -p runs/tier$TIER
gcloud storage rsync -q -r "$R/tier$TIER" "runs/tier$TIER" 2>/dev/null
for S in $STAGES; do
  $PY train_$S.py --tier "$TIER" --remote "$B"; rc=$?
  if [ $rc -eq 3 ]; then
    n=$(gcloud storage cat "$R/tier$TIER/$S/diverged_count" 2>/dev/null || echo 0); n=$((n+1))
    echo $n | gcloud storage cp - "$R/tier$TIER/$S/diverged_count"
    if [ $n -ge 2 ]; then echo "diverged twice in $S" | gcloud storage cp - "$R/tier$TIER/STOP"; fi
    exit 3
  elif [ $rc -ne 0 ]; then echo "$S failed rc=$rc"; exit $rc; fi
done

# ---- eval: each result saved to the bucket as soon as it exists; finished ones are skipped ----
mkdir -p results/tier$TIER; gcloud storage rsync -q "$B/results/tier$TIER" "results/tier$TIER" 2>/dev/null
ev() { [ -f "results/tier$TIER/$1.json" ] || $PY eval.py run --tier "$TIER" --tag "$1" $EVAL_ARGS || exit 1
       gcloud storage rsync -q "results/tier$TIER" "$B/results/tier$TIER"; }
# The decision metric runs first, so the go/no-go number arrives hours sooner.
for t in $EVAL_TAGS; do ev "$t"; done
$PY eval.py gate --tier "$TIER" | tee "results/tier$TIER/gate.txt"
gcloud storage rsync -q "results/tier$TIER" "$B/results/tier$TIER"
date -u | gcloud storage cp - "$R/tier$TIER/ALL_DONE"
echo "== $(date -u) all done"
