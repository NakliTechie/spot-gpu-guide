#!/bin/bash
# Local relaunch loop. Usage: templates/run_tier.sh TIER CAP_USD [EVAL_ARGS]  (EVAL_ARGS e.g. "--limit 20" for tier 0)
# Uploads the committed code, then keeps one spot GPU VM alive until the bucket shows ALL_DONE, STOP or ERROR,
# estimated project spend reaches CAP_USD, or MAX_LAUNCHES is hit.
# Spot preemption deletes the VM; this loop relaunches it and the job resumes from the bucket.
# GCP worked example.
#
# ======================== PLACEHOLDERS — edit these ========================
GCLOUD_CONFIG="<gcloud-config>"           # a named gcloud configuration for this project
PROJECT="<gcp-project-id>"
B="gs://<bucket>"                         # all run state lives here
PREFIX="<vm-name-prefix>"                 # VM names: $PREFIX-t<TIER>-<mmdd-HHMM>; the filter below relies on it
LABEL="<project-label>"                   # label key=true: cost allocation + IAM destructive gate
MACHINE=a2-ultragpu-1g                  # 1x A100-80 on GCP
ZONES=("<zone-a>" "<zone-b>")               # zones where you hold spot GPU quota; cheapest first
IMAGE_FAMILY="<dl-image-family>"          # e.g. a pytorch-*-cu*-ubuntu-* family in deeplearning-platform-release
MAX_LAUNCHES=25
# ===========================================================================
grep -q "^[A-Z_]*=\"[^\"]*<[a-z]" "$0" && { echo "fill the placeholders at the top of $0 first"; exit 1; }
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd) || exit 1   # spend.py and job.sh sit next to this script
cd "$HERE/.." || exit 1                          # the repo root: git archive ships HEAD from here
export CLOUDSDK_ACTIVE_CONFIG_NAME=$GCLOUD_CONFIG
TIER=$1; CAP=$2; EVAL_ARGS=${3:-}
IMG=$(gcloud compute images describe-from-family "$IMAGE_FAMILY" \
      --project deeplearning-platform-release --format='value(name)')
now() { date +%H:%M; }   # local time

# Refuse a dirty tree: the VM runs HEAD, so uncommitted edits would silently not ship.
[ -z "$(git status --porcelain -- ':!plan')" ] || { echo "commit first: the VM runs HEAD"; exit 1; }
# Gotcha: the tarball path is shared, so any relaunch uses whatever was uploaded last.
tmp=$(mktemp -d); git archive --format=tar.gz HEAD -o "$tmp/code.tar.gz"
gcloud storage cp -q "$tmp/code.tar.gz" "$B/code/code.tar.gz"
echo "$(now) code $(git rev-parse --short HEAD) uploaded; tier $TIER, cap \$$CAP"

launches=0
while true; do
  for m in ALL_DONE STOP ERROR; do
    if gcloud storage ls "$B/runs/tier$TIER/$m" >/dev/null 2>&1; then
      echo "$(now) $m: $(gcloud storage cat "$B/runs/tier$TIER/$m")"; python3 "$HERE/spend.py" | tail -1; exit 0
    fi
  done
  spend=$(python3 "$HERE/spend.py" | tail -1 | tr -dc '0-9.')
  # Unknown spend is not zero spend: a failed lookup launches nothing (GUIDE §2.4).
  [ -n "$spend" ] || { echo "$(now) spend unknown (spend.py failed): no launch this round"; sleep 180; continue; }
  if python3 -c "import sys; sys.exit(0 if $spend >= $CAP else 1)"; then
    echo "$(now) spend \$$spend >= cap \$$CAP: stopping"
    # value(name,zone.basename()) is TAB-separated: read -r splits it correctly.
    gcloud compute instances list --filter="name~^$PREFIX-t$TIER-" --format="value(name,zone.basename())" |
      while read -r n z; do gcloud compute instances delete "$n" --zone "$z" --quiet; done
    exit 2
  fi
  # A failed listing is not an empty listing: skip the round, never read it as "no VM" (GUIDE §2.4).
  live=$(gcloud compute instances list --filter="name~^$PREFIX-t$TIER-" --format='value(name)') \
    || { echo "$(now) instance list failed: skipping this round"; sleep 180; continue; }
  if [ -z "$live" ]; then
    launches=$((launches + 1)); [ $launches -gt $MAX_LAUNCHES ] && { echo "too many launches"; exit 2; }
    name=$PREFIX-t$TIER-$(date +%m%d-%H%M)
    for z in "${ZONES[@]}"; do
      # SPOT + termination DELETE + max-run-duration: the cloud-side last line of defence if this laptop dies.
      if gcloud compute instances create "$name" --project "$PROJECT" --zone "$z" --machine-type "$MACHINE" \
           --provisioning-model SPOT --instance-termination-action DELETE --max-run-duration 24h \
           --image "$IMG" --image-project deeplearning-platform-release \
           --boot-disk-size 200GB --boot-disk-type pd-balanced --scopes cloud-platform \
           --metadata ^@^tier="$TIER"@bucket="$B"@install-nvidia-driver=True@eval_args="$EVAL_ARGS" \
           --metadata-from-file startup-script="$HERE/job.sh" --labels "$LABEL=true" >/dev/null 2>"$tmp/err"; then
        echo "$(now) launch $launches: $name in $z (spend so far \$$spend)"; break
      elif grep -q -E 'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA[A-Z_]*|[A-Z_]*_EXCEEDED' "$tmp/err"; then
        echo "$(now) $z: $(grep -o -E 'ZONE_RESOURCE_POOL_EXHAUSTED|QUOTA[A-Z_]*|[A-Z_]*_EXCEEDED' "$tmp/err" | head -1)"
      else
        # Not a capacity error (e.g. a timeout after the insert was accepted): re-list before any retry, or the
        # next zone gets a twin (GUIDE §2.4).
        echo "$(now) $z: $(head -c 200 "$tmp/err"); re-listing before any retry"; break
      fi
    done
  fi
  sleep 180
done
