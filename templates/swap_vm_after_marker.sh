#!/bin/bash
# One-shot: when a bucket object appears (e.g. a stage's DONE marker), delete the running VM so the launcher
# relaunches it with the current code (e.g. a new eval order). Finished stages are skipped via DONE markers.
# Usage: templates/swap_vm_after_marker.sh TIER [BUCKET_OBJECT]   (run detached; see detach.sh)
# Re-upload the code (run_tier.sh does it) before arming.
#
# ======================== PLACEHOLDERS — edit these ========================
GCLOUD_CONFIG="<gcloud-config>"
B="gs://<bucket>"
PREFIX="<vm-name-prefix>"                 # same prefix as run_tier.sh
STAGE="<stage>"                         # stage whose DONE marker triggers the swap
# ===========================================================================
grep -q "^[A-Z_]*=\"[^\"]*<[a-z]" "$0" && { echo "fill the placeholders at the top of $0 first"; exit 1; }
export CLOUDSDK_ACTIVE_CONFIG_NAME=$GCLOUD_CONFIG; T=$1
cd "$(dirname "$0")/.." || exit 1
WAIT=${2:-runs/tier$T/$STAGE/DONE}   # bucket object to wait for, e.g. results/tierN/baseline.json
until gcloud storage ls "$B/$WAIT" >/dev/null 2>&1; do sleep 60; done
# value(name,zone) is TAB-separated; read splits on any whitespace (the first version split on a space and failed).
read -r name zone < <(gcloud compute instances list --filter="name~^$PREFIX-t$T-" --format="value(name,zone.basename())")
echo "$(date +%H:%M) $WAIT present; replacing $name ($zone) with current code" >> logs/run_tier$T.log
[ -n "$name" ] && gcloud compute instances delete "$name" --zone "$zone" --quiet >> logs/run_tier$T.log 2>&1
