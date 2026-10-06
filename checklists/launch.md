# Launch — every tier, every time

Source: GUIDE.md chapters 2–6 and 9.

## Before the first real tier
- [ ] A plumbing tier (tiny token counts, eval `--limit 20`) reached its completion marker (`ALL_DONE` from `run_tier.sh`, `DONE` from a batch job). It catches most startup-script bugs for
      about a dollar.

## Code and data
- [ ] All placeholders in `templates/` are filled. The scripts refuse to run otherwise.
- [ ] The tree is clean and committed. The launcher uploads `git archive HEAD`.
- [ ] No other launcher is about to upload a different tarball to the shared code path.
- [ ] Gated raw datasets were downloaded on the laptop and uploaded to `<bucket>/data/raw/`. No token is on the VM or
      in metadata.

## Job script (GUIDE chapters 2–3)
- [ ] `export HOME=${HOME:-/root}` is at the top.
- [ ] `exec >>"$LOG" 2>&1`, `TQDM_DISABLE=1`, `PYTHONUNBUFFERED=1`, `set -o pipefail` are set.
- [ ] The `EXIT` trap writes `ERROR` on explicit failure and deletes the VM; the name it deletes is `readonly`.
- [ ] Every stage skips itself on its `DONE` marker and resumes from the bucket.
- [ ] Artifacts mirror to the bucket as they form, out-of-band, with a final flush on `EXIT`; resume trusts a unit
      only when both its config and its weights exist (§2.11).
- [ ] No VM → bucket sync carries a delete flag; the push loop starts only after a restore-done **file** exists (§2.8).
- [ ] Evals run the go/no-go metric first.
- [ ] Python entry points `os._exit(0)` after closing outputs if they use streaming readers.
- [ ] Numeric args use `is None`, not `or`.
- [ ] `mkdir -p` precedes every copy into a directory; no gating step sends stderr to `/dev/null`.
- [ ] The job prints one `ready` line naming its inputs, and aborts when they are missing.
- [ ] Boot disk type matches the machine family; JIT builds have `g++` and `ninja`; parallel builds use an explicit
      `-j N`.

## Launcher (GUIDE §2.4, §2.10, chapter 9)
- [ ] A batch or eval job runs under a relaunch loop with a `DONE` marker, never from a one-shot launcher.
- [ ] Results go to one fixed campaign path; the runner resumes per unit.
- [ ] The launcher runs detached (`templates/detach.sh`) or as a launchd agent; the cap fits under the written stop
      rule, counting other projects' spend.
- [ ] Every instance carries the project tag (in every task file) and a max run duration.
- [ ] With an orchestrator: its local server runs under **this** project's identity; long runs are detached; every
      GPU pass is a job, so autostop sees it.

## Serverless GPU endpoint (GUIDE chapter 5)
- [ ] Max instances is 1; the window estimate counts cold start + idle tail, and the cap fits the stop rule.
- [ ] One driver per window with a watchdog that kills the clients and both proxy processes at the time cap.
- [ ] Every remote read is cached; downstream steps run with the endpoint URL on a closed port.

## Local Apple GPU (GUIDE §6.2)
- [ ] One GPU job per machine: a lock around train → score → move to CPU; the driver refuses to start beside another
      job.
- [ ] Both MPS watermark ratios set; a memory guard reads `top`, not `ps`.

## Supervision (GUIDE chapter 4)
- [ ] Tier 1: a re-armed background `sleep 900` timer drives check-ins (not a session cron alone).
- [ ] Tier 1 reads the bucket log for the `ready`/`healthy` line 5–8 min after every launch.
- [ ] The watchdog is a real script, emits every interval, alerts on every terminal state and on the box vanishing,
      and was tested against a box known to be up (§4.8).
- [ ] An unattended run has a nightwatch with a hard deadline, bounded retries and a final all-region sweep (§4.9).
- [ ] The check-in command runs unpiped; `tail -1` on the ledger confirms the write.
- [ ] Before killing any watcher, its working directory and launchd label were checked (§4.10).
- [ ] Tier 2: a detached supervisor runs as a launchd agent, so it survives a reboot.
- [ ] `watch.sh` follows the newest job log, including one that started before it.
