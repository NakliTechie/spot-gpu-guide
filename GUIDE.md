# Remote GPU orchestration — the field guide

Run training, eval and inference jobs on rented GPUs from a laptop, unattended, without losing work or money.

Every rule here comes from a failure in a real run. Each has three parts: the rule, the failure mode it prevents,
and the fix, usually with a snippet. A few rules come from a published write-up instead; those are marked
**Published** and link their source. The scripts named here live in [`templates/`](templates/). GCP is the worked
example for scripts; AWS-specific rules are marked **AWS**, and §9 covers orchestrators such as SkyPilot.

Chapters: [1 Account, quota, billing](#1-account-quota-billing--before-any-code) ·
[2 A job that survives spot](#2-a-job-that-survives-spot) ·
[3 Startup-script and VM gotchas](#3-startup-script-and-vm-gotchas) ·
[4 Supervision](#4-supervision--who-watches-the-watchers) ·
[5 Serverless GPU endpoints](#5-serverless-gpu-endpoints) ·
[6 The laptop](#6-the-laptop) ·
[7 Planning a run](#7-planning-a-run) ·
[8 Reference numbers](#8-reference-numbers) ·
[9 Orchestrators (SkyPilot)](#9-orchestrators-skypilot)

---

## 1. Account, quota, billing — before any code

### 1.1 Plan for one GPU
- **Rule.** Design the run around 1 GPU until a quota increase is granted.
- **Failure mode.** New accounts are usually granted a project-wide GPU quota of 1. Larger requests are denied, and a
  support case takes days. The project-wide cap binds even when a region shows more.
- **Fix.** Run on 1 GPU and make every stage resumable. Cost follows GPU-hours, not GPU count: 1 GPU at 8× the
  wall-clock costs the same as 8 GPUs. You pay in time and in preemption exposure.
- **Consequence.** With a quota of 1, jobs queue: an eval VM can only start once the training VM is gone. A launcher
  that waits for a stop marker plus no running VM does this unattended.

```bash
gcloud compute project-info describe --format="table(quotas.metric,quotas.limit,quotas.usage)" | grep -i gpu
gcloud compute regions describe <region> --format=json | grep -B1 -A2 PREEMPTIBLE_NVIDIA
```

### 1.2 Billing account limits
- **Rule.** A billing account caps linked projects (5 on GCP). A 6th link fails with `FAILED_PRECONDITION`; unlink an
  unused project first.
- **Rule.** GCP's Free Trial blocks GPUs. Upgrade to paid; the trial credit survives the upgrade and expires 90 days
  after signup.

```bash
gcloud billing projects list --billing-account=<BILLING_ACCOUNT_ID>
gcloud billing projects unlink <unused-project-id>
```

### 1.3 Budgets alert; they never stop spend
- **Rule.** Set budgets in the billing currency, with credits excluded, account-wide, plus a written stop rule.
- **Failure modes.** A USD amount on a non-USD billing account returns `INVALID_ARGUMENT`. With credits included, the
  alert tracks what you owe, not what you burn. Per-project budgets do not see each other.
- **Stop rule.** Alerts only send email. Write the stop rule down, for example: stop all GPU work at 90 % of the
  credit, counted across every project on the billing account.

```bash
gcloud billing budgets create --billing-account=<BILLING_ACCOUNT_ID> \
  --display-name="all-projects-burn" --budget-amount=<AMOUNT><CURRENCY> \
  --credit-types-treatment=exclude-all-credits \
  --threshold-rule=percent=0.5 --threshold-rule=percent=0.9
```

### 1.4 Prices come from the catalog
- **Rule.** Read prices from the Cloud Billing Catalog API, not from memory, and record the read date.
- **Rule.** A VM's rate is GPU + host vCPU + host RAM. The host part is not small: about $0.6/h on a 1-GPU A100 shape.
  [`templates/spend.py`](templates/spend.py) holds the formula.

### 1.5 A scoped identity per project, never admin keys
- **Rule.** Launch with a dedicated identity per project (an IAM user or service account) holding one
  least-privilege policy. Never use admin keys or an admin role for launches. Keep the admin identity keyless (a
  short-lived login session), and keep scoped keys in env or a secret store, never in the repo.
- **Rule.** Region-lock only **mutating** actions. Locking read-only `Describe*` breaks every launch, because the
  launcher must enumerate regions and zones to choose one.
- **Rule.** Gate destructive actions (terminate, stop) on a project tag (`<project>=true`) as well as the region. A
  bug or typo then cannot touch anything else. The same tag does cost allocation.
- **Failure mode.** An instance launched without the tag cannot be torn down by the scoped identity, and an
  autostop that relies on it fails: a runaway-cost trap. Put the tag in every task definition.
- **Rule.** Gate teardown on the project tag, never on a shared identity or OS user: shared infrastructure (for
  example an orchestrator's controller) may be serving another project.
- **Rule (AWS).** The scoped identity cannot read spend by design (`ce:GetCostAndUsage` needs admin). The pricing
  API (`pricing:GetProducts`) is the public rate card, not spend; it is safe to grant.
- **Rule (AWS).** Prefer a customer-managed policy: inline user policies cap at 2,048 characters in aggregate, and a
  multi-region policy overflows it. A `_comment` field in the JSON breaks both the CLI and the console paste.
- **Verify** with a dry run, not by reading the policy: a policy that applied is not a policy that works.

```bash
aws sts get-caller-identity --profile <project>-launcher        # the scoped identity, not admin
aws ec2 run-instances --dry-run --region <r> --image-id ami-0 --instance-type <type> --profile <project>-launcher
# DryRunOperation / InvalidAMIID = past the IAM gate; UnauthorizedOperation = still blocked
```

### 1.6 Spot GPU quota (AWS)
- **Rule.** G-family spot quota ("All G and VT Spot Instance Requests", vCPU-based) starts at 0 and is **per
  region**. New GPU families go through a human review with partial grants. Request it in every region you will use,
  on day one.
- **Rule.** Check before assuming you are blocked: once an account has usage, the quota can be raised account-wide,
  and a new region may already be usable.
- **Gotcha.** A just-terminated instance stays `shutting-down` and still counts against the vCPU quota; a relaunch
  fails `VcpuLimitExceeded` until it reaches `terminated`.

```bash
for r in <regions>; do echo -n "$r "; aws service-quotas get-service-quota --service-code ec2 \
  --quota-code L-3819A6DF --region $r --query 'Quota.Value' --output text; done
```

### 1.7 Price is not capacity
- **Rule.** A spot price listing is a rate card, not availability: the cheapest region can have no capacity in any
  zone. Treat a price survey as a shortlist, keep 3+ regions allowed, and let the launcher fail over rather than
  pinning one region for a few cents.

### 1.8 Preflight each region's network
- **Failure mode (AWS).** A region's default VPC can route `0.0.0.0/0` to a **detached** internet gateway (state
  `blackhole`). Boxes launch with public IPs and an open security group, and SSH times out on every one.
- **Rule.** A fleet-wide SSH **timeout** with an open security group means routing, not the security group
  ("refused" points at the SG or daemon). Check the main route table before relying on a region; re-attaching the
  gateway needs admin.

```bash
aws ec2 describe-route-tables --region <r> --filters Name=association.main,Values=true \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].[GatewayId,State]' --output text
```

### 1.9 Keep chatty components in one region
- **Rule.** Pin the controller (trainer, driver, launcher-side service) and the GPU workers it calls to one region,
  and check where the provider actually placed them before a long run. A per-call round trip is invisible in a
  smoke test and dominant at scale.
- **Published.** A trainer placed in `eu-north-1` with its inference replicas in US West crossed the Atlantic on
  every model call; at ~100 calls per rollout that was minutes of pure network wait per rollout. The fix there was
  to move the capture step into the replica ([Proximal, *Post-training infrastructure*](https://www.proximal.so/blog/posttraining-infra/)).

### 1.10 Cost tags lag; keep a local ledger
- **Rule.** Cost-allocation tags must be activated in billing and take about a day to populate. Activate them early,
  and keep a local launch ledger (§7.4) to bridge the lag.
- **Rule.** Add a daily GPU-spend alert scoped by **instance family** (G/P on AWS), not by service or tag: it then
  catches every project's GPU spend in a mixed account, including launches someone forgot to tag.

---

## 2. A job that survives spot

### 2.1 One idempotent job script
- **Rule.** One self-contained job script runs as the VM startup script. Every step resumes from the bucket: data →
  train stages → eval → gate. `DONE` markers skip finished stages.
- **Template.** [`templates/job.sh`](templates/job.sh).

### 2.2 State lives in the bucket, never on the VM
- **Rule.** Keep checkpoints (full resume state + light weights), the metrics log, eval results and the job log in
  the bucket. Push the job log every 2 min. Spot termination deletes the VM and its disk.

```bash
( while sleep 120; do gcloud storage cp -q "$LOG" "$B/logs/" 2>/dev/null; done ) &
```

### 2.3 Self-deleting VMs
- **Rule.** Every VM deletes itself on success, failure and preemption.
- **Fix.** Three layers: spot termination action `DELETE`, `--max-run-duration`, and an `EXIT` trap that deletes the
  VM. An explicit failure writes an `ERROR` marker, so the launcher stops instead of looping.
- **Gotcha.** Make the name the trap deletes `readonly`. A loop variable that reuses it makes the trap delete the
  wrong thing and leave the real VM running to its cap.

```bash
gcloud compute instances create "$name" ... \
  --provisioning-model SPOT --instance-termination-action DELETE --max-run-duration 24h
# in job.sh
readonly SELF=$(hostname)
finish() { rc=$?; [ $rc -ne 0 ] && [ $rc -ne 3 ] && echo "rc=$rc" | gcloud storage cp - "$R/ERROR"
           gcloud compute instances delete "$SELF" --zone "$ZONE" --quiet; }
trap finish EXIT
```

### 2.4 A relaunch loop with a spend cap
- **Rule.** A local loop keeps one VM alive until `DONE`, `STOP` or `ERROR`, under a USD cap and a max-launch
  (life) count. Run it as a launchd agent so it survives a reboot (§4.7).
- **Spend.** Pair each `insert` operation with its `delete` or `preempted` operation and multiply by the catalog rate.
  Skip failed creates (no capacity).
- **Rule.** A failed listing is not an empty listing. Every "no VM → launch" decision checks the listing command's
  exit code; on failure the loop skips the round. Count `STOPPING` instances as present. A transient listing failure
  read as "no VM" launches a second VM next to the running one, and two lives writing one checkpoint path is the worst
  outcome a relauncher can produce.
- **Rule.** Unknown spend is not zero spend. If the spend lookup fails, the loop launches nothing that round and
  alerts; a cap fed by an empty or failed lookup can never fire.
- **Rule.** Move to the next zone only on a capacity or quota error. Any other create failure (a client timeout after
  the insert was accepted) re-lists first, or the retry creates a twin.

```bash
out=$(gcloud compute instances list --filter="name~^$PREFIX-" --format='value(name,status)') \
  || { echo "listing failed; skip"; sleep 60; continue; }
```
- **Templates.** [`templates/run_tier.sh`](templates/run_tier.sh) (staged training),
  [`templates/relaunch.sh`](templates/relaunch.sh) + [`templates/job.env.example`](templates/job.env.example) (any
  startup script), [`templates/launcher.plist`](templates/launcher.plist), [`templates/spend.py`](templates/spend.py).

### 2.5 Ship code as `git archive HEAD`
- **Rule.** The launcher refuses a dirty tree, so the VM always runs a commit.
- **Gotcha.** The tarball path in the bucket is shared: a relaunch uses whatever was uploaded last.
- **Gotcha.** A running VM keeps the startup script it booted with; an edit applies only to the next life. If you
  change the completion protocol mid-campaign, write the marker by hand for the life in flight, or the loop mistakes
  its clean finish for a preemption and relaunches to redo finished work.

```bash
[ -z "$(git status --porcelain -- ':!plan')" ] || { echo "commit first: the VM runs HEAD"; exit 1; }
git archive --format=tar.gz HEAD -o "$tmp/code.tar.gz" && gcloud storage cp -q "$tmp/code.tar.gz" "$B/code/code.tar.gz"
```

### 2.6 Data
- **Rule.** Tokenize once into flat memmaps. Resume by sequence offset; do not re-stream.
- **Rule.** Download gated datasets on the laptop with your token and upload the raw file to the bucket. **Never put
  the token on the VM** or in its metadata.

### 2.7 Preemption notice is short
- **Fact.** GCP gives ≈ 30 s notice (metadata `instance/preempted`, ACPI soft-off). AWS gives 2 min.
- **Rule.** A full resume state for a model of ~1B parameters is ~15 GB: too big for 30 s. Checkpoint often and upload
  in the background (§2.8). Use the notice only to flush logs and results. Both job templates run a notice watcher
  that does exactly that.

```bash
# GCP: blocks until the value changes; TRUE means the notice has arrived
curl -sf -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/preempted?wait_for_change=true"
# AWS (IMDSv2): 404 until a notice is issued, then JSON with the action and time; poll every 5 s
TOK=$(curl -sX PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
curl -sf -H "X-aws-ec2-metadata-token: $TOK" http://169.254.169.254/latest/meta-data/spot/instance-action
```

### 2.8 Checkpoints: never sync with delete; push only after restore
- **Failure mode.** A fresh VM's push loop runs a sync with a delete flag from an empty local checkpoint directory
  before the restore finishes, and wipes the bucket's checkpoints. The next life restarts from step 0.
- **Rule.** No delete flag on any VM → bucket sync, ever. The push loop starts only after a restore-done marker
  exists. Refuse to start at step 0 when the bucket holds step rows.
- **Rule.** The restore-done marker is a **file**, not a shell variable: a push loop forked with `( … ) &` never sees a
  variable set after the fork.
- **Rule.** Upload each checkpoint in the background, and move the bucket's `LATEST` pointer only after that step's
  upload has finished. A preemption mid-upload then leaves `LATEST` on the previous complete step, never on a half
  copy. Size the interval so one upload finishes well inside it.

```bash
gcloud storage rsync -r ckpt "$B/ckpt"            # never --delete-unmatched from the VM
[ -f /opt/run/.restored ] || echo "restore not done: no push"
# after writing ckpt/step$N locally: push it, then point LATEST at it, all off the training path
( gcloud storage rsync -r "ckpt/step$N" "$B/ckpt/step$N" && echo "step$N" | gcloud storage cp - "$B/ckpt/LATEST" ) &
```

### 2.9 Checkpoint protocol for adapter (LoRA) training
- **Rule.** A checkpoint is adapter + optimizer + RNG state, written to `stepN/`, with `LATEST` written last. Keep the
  newest 3. Archive every Mth adapter (weights only) to `saves/`: cheap, and the only way to re-evaluate earlier steps
  later. When `ckpt/` is empty, restore from the newest `saves/` entry (adapter only, optimizer reset).
- **Rule.** Worst-case loss per preemption = checkpoint interval + upload time + relaunch overhead (dependency
  install + inference server start).
- **Gotcha.** Match `step\d+` exactly when listing checkpoints; keep derived directories (e.g. merged or converted
  weights) elsewhere, or the lister crashes on them.

### 2.10 Batch jobs (evals, sweeps) are training runs without an optimizer
- **Failure modes.** A one-shot launcher starts the eval VM once; a preemption ends the eval and nothing relaunches.
  A per-boot results path makes a relaunch redo every finished unit.
- **Fix.** One fixed campaign path per job. The job restores it at boot; the runner skips units already recorded in
  its `runs/<tag>.jsonl` (per unit, not per tag, so a long eval survives a mid-run preemption). A relaunch loop keeps
  the VM alive until a `DONE` marker, under a life cap and a spend cap. Template:
  [`templates/batch_job.sh`](templates/batch_job.sh).

### 2.11 Mirror artifacts as they form; resume only from complete ones
- **Failure mode.** A run that trains fine but dies in a downstream step (serve, eval) re-pays the full training
  cost on every retry when nothing was persisted.
- **Rule.** Mirror artifacts to the bucket on a short interval and once more in an `EXIT` trap. Mirror
  **out-of-band** (a background copy): keep the training write path on local disk and let only the copy touch a
  FUSE-mounted bucket, so a mount stall cannot corrupt a save.
- **Rule.** On resume, skip a unit only when **both** its config and its weights file exist; a partial save is
  retrained, never trusted.
- **Rule.** Tune cross-region bucket copies: default CLI concurrency crawls on large artifacts; more parallel
  requests with larger chunks copy several times faster.

```bash
mkdir -p artifacts "$MNT/artifacts"; cp -ru "$MNT/artifacts/." artifacts/ 2>/dev/null || true      # resume
( while true; do cp -ru artifacts/. "$MNT/artifacts/" 2>/dev/null || true; sleep 60; done ) & M=$!
trap 'cp -ru artifacts/. "$MNT/artifacts/" 2>/dev/null || true; kill $M 2>/dev/null' EXIT
```

### 2.12 Let capacity change without a restart
- **Rule.** Save the unconsumed work queue (finished rollouts, scored items, anything produced but not yet used) with
  every checkpoint, to durable storage. A resume after an outage then loses no finished work, only what was in
  flight.
- **Rule.** A worker that joins mid-run reads the current weights from the bucket or volume, then receives every
  later update. Capacity can then grow, or replace preempted workers, while the job keeps running.
- **Published.** An RL run on preemptible single-GPU workers lost 40 % of its inference capacity mid-step; all 128
  GPUs were serving again 19 minutes later and the step took 37 minutes against 35 for its neighbours. It resumed
  from a rollout store saved with each checkpoint ([Proximal, *Post-training infrastructure*](https://www.proximal.so/blog/posttraining-infra/)).

---

## 3. Startup-script and VM gotchas

Each one kills a run. A plumbing tier (tiny token counts, eval `--limit 20`) catches most of them for about a dollar.
Run one before any real tier.

| Rule | Failure mode | Fix |
|---|---|---|
| Startup scripts run as root with no `HOME` | `set -u` + `$HOME` → instant exit | `export HOME=${HOME:-/root}` |
| Never write progress bars to the script runner | The GCE runner reads stdout line by line, 64 KB max. A progress bar redrawn with `\r` grows past that; the job dies of SIGPIPE with no `ERROR` marker, so the launcher relaunches it | `exec >>"$LOG" 2>&1` (never tee to the runner) and `TQDM_DISABLE=1` |
| Unbuffer Python | Pipe stdout is block-buffered; logs appear an hour late | `PYTHONUNBUFFERED=1` |
| Exit hard after outputs close | Abandoned streaming dataset readers can crash CPython at shutdown, turning success into rc ≠ 0 | `os._exit(0)` after every output is closed |
| `0` is falsy | `args.tier or default` runs tier 0 at the default size | `default if args.tier is None else args.tier` |
| `gcloud --format="value(a,b)"` is tab-separated | Splitting on a space breaks the script | `read -r a b` |
| Build bucket paths from one explicit root | `$B/../data/x` matches nothing: `gcloud storage` does not resolve `..` in `gs://` URLs, so the job aborts at boot (a ready-line gate holds such a life to cents) | `ROOT=gs://bucket; B=$ROOT/run; … $ROOT/data/x` |
| `mkdir -p` before `gcloud storage cp` into a directory | "Destination URL must name an existing directory" | `mkdir -p <dir>` first, wildcard copies too |
| Never `>/dev/null 2>&1` a gating step | Failed copies vanish; the job runs with empty inputs and pays for a no-op | `set -o pipefail` and `2>&1 \| grep -i error` at least |
| One `ready` line, then a gate | Nothing in the log says what the job is about to process | Print the inputs on one greppable line; `exit 0` (self-delete) when they are not what the job is for |
| Boot disk type follows the machine family | Some families reject `pd-balanced` | e.g. `--boot-disk-type hyperdisk-balanced` on g4 |
| Deep-learning VM images may lack build tools | JIT kernel builds fail at inference-server start | `apt-get install -y g++`; put the venv's `bin` on PATH for `ninja` |
| zsh globs `gs://…/*` | Mac-side helper scripts die with "no matches found" | `setopt NO_NOMATCH`, or quote the URL |
| Starting a background job over ssh | `ssh box 'nohup x &'` hangs the caller | `ssh box 'setsid -f nohup x > log 2>&1 < /dev/null'` |
| Bound parallel builds | Unbounded `make -j` on CUDA builds runs out of memory; inside some job runners `nproc` returns 1 | An explicit `-j N`; set the CUDA architectures so it does not build every one |
| Retry package mirrors | Image builds fail on transient mirror 404s | Retry `apt-get` (`--fix-missing`) and fail only when every attempt fails |

```bash
export HOME=${HOME:-/root}
exec >>"$LOG" 2>&1
export PYTHONUNBUFFERED=1 TQDM_DISABLE=1
set -o pipefail
read -r name zone < <(gcloud compute instances list --filter="name~^$PREFIX" --format="value(name,zone.basename())")
```

---

## 4. Supervision — "who watches the watchers"

### 4.1 Two tiers
Two words used below. **Tier 1** is whoever runs the jobs: you, or an AI coding agent working for you. The **ledger**
is a one-line-per-check timestamp file that tier 1 appends to on each check-in; tier 2 reads its age.

- **Tier 1.** The agent checks each job every 15 min against real evidence: alive, output growing, on task, spend. It
  stamps a ledger.
- **Tier 2.** A detached supervisor alerts the human directly when the ledger goes stale or a job overruns its ETA.
  Tier 1 lapses happen; tier 2 is what catches them.

### 4.2 Waiting is not watching
- **Rule.** A completion waiter misses a mid-run crash or a job doing the wrong thing. Check real evidence each pass.

### 4.3 Tier 1 reads the boot, not only the VM list
- **Failure mode.** A VM that is up and doing the wrong thing looks alive to every existence probe.
- **Fix.** 5–8 min after each launch, read the bucket log for the `ready`/`healthy` line.

### 4.4 Session crons are not a reliable tier 1
- **Fix.** Drive check-ins with a re-armed background `sleep 900` timer, not a session cron alone.

### 4.5 Never pipe the check-in command
- **Failure mode.** `checkin … | head -1` closes the pipe and kills the command before its ledger write; the
  supervisor then raises a false lapse alert.
- **Fix.** Run the check-in unpiped. Confirm with `tail -1` on the ledger.

### 4.6 A log follower must handle logs older than itself
- **Failure mode.** A follower that skips logs started before it goes silent.
- **Fix.** On first read, start from the log's current end and emit only new lines. See
  [`templates/watch.sh`](templates/watch.sh).

### 4.7 Detach properly, and survive reboots
- **Failure mode.** `nohup … & disown` does not survive an agent session's teardown. A laptop crash or reboot kills
  every locally started watcher; the cloud job runs on unwatched.
- **Fix.** `setsid` + double fork, so the process is re-parented to launchd (ppid 1):
  [`templates/detach.sh`](templates/detach.sh). For anything that must outlive a reboot (supervisor, relaunch loop),
  use a launchd agent with `RunAtLoad` + `KeepAlive`: [`templates/supervisor.plist`](templates/supervisor.plist),
  [`templates/launcher.plist`](templates/launcher.plist). The real last line of defence is cloud-side: spend cap,
  `--max-run-duration`, self-deleting VMs.

```bash
templates/detach.sh logs/run.pid bash -c 'templates/run_tier.sh <N> <CAP_USD> >> logs/run.log 2>&1'
```

### 4.8 A watchdog that can lie is worse than none
- **Rule.** Whenever a GPU box is up, an out-of-band watchdog polls it at 15 min or less. Autostop is a cost guard,
  not a health guard: it says nothing while a job is dying.
- **Requirements**, each learned from a defect:
  - a real script file, not an inline shell blob (inline multi-line loops lose word-splitting and report live
    boxes as gone);
  - one line every interval, not only on failure, so silence means "the watchdog died";
  - an alert on every terminal state (`FAILED*`, `CANCELLED`, preempted) **and** on the box vanishing: a spot
    reclaim looks like absence, not an error;
  - no `set -e`: one flaky API call must not kill the watch;
  - tested against a box you know is up before you trust it.

### 4.9 An unattended run gets a nightwatch with a hard deadline
- **Rule.** A run you walk away from gets a detached nightwatch whose first duty is a **hard deadline** that
  terminates everything regardless of state, so a hung job cannot bill until morning.
- **Rule.** At most one bounded retry per job after preemption, only when enough deadline remains to finish;
  unbounded retries burn money unattended.
- **Rule.** End with a sweep across **every** allowed region, terminating anything still carrying the project tag,
  and a report readable cold (per-job outcome, artifact paths, what is still up).
- **Gotcha.** macOS `/bin/bash` is 3.2: `declare -A` fails and every key collapses to one index. Use parallel indexed
  arrays, and never send a watcher's stderr to `/dev/null`.

### 4.10 One supervisor per scope, owned by launchd
- **Failure mode.** A second agent session kills the running supervisor and starts its own; two copies race on one
  ledger. `pgrep -f "<supervisor>"` matches every project's copy, so a session can kill another project's watcher.
- **Rule.** Before starting or killing a watcher, read its working directory and its launchd label. Leave anything
  launchd owns alone; a session that needs the supervisor reads its status and does not touch the process.

```bash
lsof -p "$PID" | awk '$4=="cwd"{print $NF}'
launchctl print gui/$(id -u)/<label> | grep -E 'state|pid|last exit'
```

### 4.11 Retire means bootout and delete
- **Failure mode.** A finished run's agent is booted out but its plist stays in `~/Library/LaunchAgents`; `RunAtLoad`
  restarts the dead run's loop at the next login.
- **Rule.** `launchctl bootout`, then delete the plist file, the day the run ends.

---

## 5. Serverless GPU endpoints

A scale-to-zero GPU service (e.g. Cloud Run with a GPU) serving a model that a laptop calls in batches.

### 5.1 Billing follows uptime, not calls
- **Rule.** Cost = (cold start + busy time + idle tail before scale-down) × hourly rate. Batch remote work into
  windows, and run every job that needs the endpoint inside one window.
- **Rule.** A window opened soon after another starts warm: the instance never scaled down, so it billed the whole
  gap. Count back-to-back windows as one continuous uptime.
- **Fix.** Pin max instances to 1 so the hourly rate is a hard ceiling. Estimate a window as
  calls ÷ throughput + cold start + idle tail, before opening it.

```bash
gcloud run services describe <svc> --region <region> --format="value(spec.template.metadata.annotations)" | tr ';' '\n' | grep -i scale
until curl -s -m 200 -o /dev/null -w "%{http_code}" localhost:<port>/<cheap-endpoint> | grep -q 200; do sleep 5; done   # warm-up
```

### 5.2 The local proxy is two processes
- **Failure mode.** Killing the shell that ran `gcloud run services proxy` leaves the `cloud-run-proxy` child
  listening, and the gcloud parent can start a new child.
- **Fix.** Kill both, then prove the port is free.

```bash
pkill -f "run services proxy <svc>"; pkill -f "cloud-run-proxy -host https://<svc>"
lsof -iTCP:<port> -sTCP:LISTEN -t || echo "proxy down"
```

### 5.3 Cache every remote read; prove zero spend with a closed port
- **Rule.** Append every remote answer to a local cache (JSONL keyed by a hash of model + request; skip a line torn by
  a crash). A killed or capped window resumes by skipping cached rows.
- **Rule.** After the window, run every downstream step with the endpoint URL pointed at a closed port
  (`http://127.0.0.1:9`). Any uncached read then fails loudly instead of quietly billing.

### 5.4 One driver per window, with a watchdog
- **Rule.** One detached driver opens the proxy, warms the endpoint, runs the queued clients in order, stops the
  proxy, and logs the window length. A separate watchdog kills the clients and both proxy processes at a time cap;
  the service then scales to zero on its own.
- **Rule.** The driver refuses to start when another job of the same project is running, and keeps a pidfile.

---

## 6. The laptop

### 6.1 Disk
- **Rule.** Keep checkpoints and datasets off the laptop. Test with tiny random models. Clean model caches per
  project.

```bash
df -h ~ ; du -sh ~/.cache/huggingface
```

### 6.2 The local GPU: one job at a time
- **Failure mode.** Two training jobs on an Apple-silicon GPU at once can exhaust unified memory and panic the kernel
  (`IOGPUGroupMemory`). The reboot kills every local watcher (§4.7).
- **Rule.** Keep heavy compute on the rented GPU. When local GPU work is unavoidable:
  - take a machine-wide lock (`fcntl.flock` on one file) around each unit of GPU work: train → score → move the model
    to CPU. The lock is not re-entrant; take it once per unit;
  - stop the loop, not the child: a `for` loop moves on to its next item when only its child dies;
  - cap PyTorch's share of GPU memory, setting **both** ratios (the high one alone, below the default low of 1.4,
    fails every MPS load with "invalid low watermark ratio");
  - read memory with `top`, not `ps`: `ps -o rss` can show megabytes for a process holding gigabytes of GPU memory.
    Kill any job above a threshold.

```python
import os
os.environ.setdefault("PYTORCH_MPS_HIGH_WATERMARK_RATIO", "0.5")
os.environ.setdefault("PYTORCH_MPS_LOW_WATERMARK_RATIO", "0.4")   # must not exceed the high ratio
import torch  # after the env vars
```

```bash
top -l 1 -pid "$PID" -stats mem | tail -1          # real footprint on Apple silicon
```

| Rule | Failure mode | Fix |
|---|---|---|
| Keep sequence length short on MPS for large-vocabulary models | Memory grows past 10 GB at 256 tokens where 64–128 holds steady | Cap `max_length` |
| Move a finished model off the GPU at once | Several trained models held on MPS until saving add up to over 10 GB | `model.to("cpu")`, `gc.collect()`, `torch.mps.empty_cache()` after scoring |
| Pad batches to one shape in a long training loop | Varying padded shapes grow memory until a guard kills the job | `padding="max_length"` |
| CPU is not a fallback for large models | A 1B-parameter CPU probe takes minutes per handful of prompts | Use the rented GPU |

### 6.3 Crash forensics
- **Rule.** Read the panic report, not the uptime. On macOS, `/Library/Logs/DiagnosticReports/panic-full-<time>.panic`
  is named at the next **login**, not at the panic. The JSON body's `Calendar` epoch is the panic time; `processByPid`
  lists every process with `residentMemoryBytes`, which names the culprits.

```bash
python3 - <<'PY'
import json; raw=open('/Library/Logs/DiagnosticReports/<file>.panic').read()
d,_=json.JSONDecoder().raw_decode(raw[raw.index('\n')+1:])
for pid,p in d['processByPid'].items():
    if p.get('residentMemoryBytes',0)>2e9: print(pid,p['procname'],round(p['residentMemoryBytes']/1e9,1),'GB')
PY
```

### 6.4 Environment gotchas
| Rule | Failure mode | Fix |
|---|---|---|
| Tokens exported in `~/.zshrc` are invisible to non-interactive shells | CLIs report "not logged in"; gated downloads return 401 | `zsh -ic '<command>'`, or export in `~/.zshenv` |
| Load cached Hugging Face models offline | Loads stall for minutes on hub metadata checks | `HF_HUB_OFFLINE=1` once the model is cached |
| A partial model download looks like a cache hit | `from_pretrained` finds a cache folder without weights | `hf download <repo>` once, then load offline |

---

## 7. Planning a run

### 7.1 Decision metric first
- **Rule.** Order evals so the go/no-go metric runs first; it then arrives hours sooner.
- **Mid-run change.** To apply a new eval order to a running VM, re-upload the code and delete the VM once training
  is `DONE`; the launcher relaunches it with the new code. See
  [`templates/swap_vm_after_marker.sh`](templates/swap_vm_after_marker.sh).

### 7.2 An eval set with headroom
- **Failure mode.** A held-out set the base model already nearly solves saturates within a few training steps and
  can show nothing more.
- **Rule.** Check the base model's score first. Archive checkpoints (§2.9) and keep an outside benchmark for the real
  measure.

### 7.3 Write the early-stop rule before launch
- **Rule.** Watch the learning signal, not only the loss. In RL, track how many groups still carry gradient per
  step; when it falls toward zero, the run has stopped learning. Write the stop condition and what to do next (keep
  the checkpoint, move to a harder pool) before launch.

### 7.4 Log every VM life, failures included
- **Rule.** One row per VM life: start, end, minutes, how it ended, rate, estimated cost, purpose, outcome. Take the
  mechanical columns from the operations log (`spend.py` style) and add the last two by hand. Keep a running total in
  the project README. A failed life gets a row too; its cost is the lesson's price tag.

---

## 8. Reference numbers

For calibration only. Prices are catalog reads from September 2026; re-read them for your region and date (§1.4).

| Item | Value |
|---|---|
| Spot A100-80 GPU (GCP) | $1.30/h (cheapest US region) to $2.65/h; ≈ $1.94/h with host CPU + RAM on a 1-GPU shape |
| Spot `g4-standard-48` (1× RTX PRO 6000 96 GB, 48 vCPU, 180 GB) | $1.77/h; on-demand ≈ $4.50/h |
| Cloud Run GPU service, 1× RTX PRO 6000 | ≈ $3.19/h while an instance is up; cold start ~2 min for a ~26B-parameter NVFP4 model; ~20 calls/s at 8 parallel callers |
| Spot preemption, observed | from 37 min to over 6 h into a life |
| Relaunch overhead (deps + inference server start) | 6–8 min |
| Losing 40 % of serving capacity mid-step, self-healing (published, §2.12) | step 37 min vs 35 min; full capacity back in 19 min |
| Plumbing tier (catches most gotchas) | about $1 |
| Training throughput, 1× A100-80 | 350M model: 21.9k tok/s (16 % MFU); 1.2B: 8.3k tok/s (19–22 % MFU) |
| vLLM, 4B model, bf16, short replies, RTX PRO 6000 | 136 / 764 / 2,280 tok/s at concurrency 1 / 8 / 32 |
| Apple-silicon laptop, 24 GB | a 17M-parameter encoder fine-tunes on ~11k short texts in about a minute; a 140M one in 6–10 min at 64 tokens |

---

## 9. Orchestrators (SkyPilot)

An orchestrator (SkyPilot, dstack) handles launch, failover and teardown across regions and clouds. Chapters 1–4
still apply; these rules are specific to running one.

| Rule | Failure mode | Fix |
|---|---|---|
| The local API server uses the identity it was **started** with | On a machine shared by several projects, a launch with another project's profile is provisioned with whichever identity started the server; tag-gated teardown then fails | Before each project's launch, stop the API server and restart it under that project's profile; assert the key resolves to the expected identity |
| Detach long runs | An attached launch that streams logs dies with the client (terminal closed, agent turn ended): `FAILED_DRIVER` mid-run | `sky launch -d`, `sky exec -d`, or managed jobs; poll with `sky queue` / `sky logs` |
| Autostop counts orchestrator **jobs**, not GPU work | Work started over plain ssh is invisible; the box is torn down mid-benchmark once the last job ends | Run every GPU pass as a job (`run:` block or `sky exec -d`); if work must run outside a job, cancel autostop and set an on-box `shutdown -h +N` deadline |
| A failed `setup:` does not stop `run:` | A failed image build still starts the run | Re-check the artifact in `run:` and `exit 1` if it is missing |
| Tag every task | Without the project tag in `resources.labels`, the scoped identity cannot tear the box down (§1.5) | Put the tag in every task file; recover by tagging the instance with admin, then tear down |
| Never tear down the shared controller | The managed-jobs controller is untagged and may be running another project's jobs | Gate teardown on the project tag; leave a stopped controller parked (it costs pennies) |
| Keep instance types flexible | Pinning one type misses cheaper equivalents; per-(type, zone) spot pools make a bigger box cheaper at times | Specify `accelerators: <GPU>:1` plus a memory floor, not an instance type |
| Scope watchers to one run's folder | Workdir sync carries old result folders | Point watchers at the current run's directory only |
