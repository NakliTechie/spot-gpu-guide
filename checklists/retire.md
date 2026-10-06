# Retire — when the work ends

Leave nothing billing, nothing watching, nothing cached. Source: GUIDE.md chapters 2, 4, 5, 6.

## Cloud
- [ ] No VMs left in **any** allowed region: list instances with the project tag in each one.
- [ ] No orphaned disks from this project.
- [ ] No serverless endpoint instance is still up; the service has scaled to zero.
- [ ] Final spend recorded (`python3 templates/spend.py | tail -1`), with the date, in the project's history.
- [ ] Every VM life has a row in the spend log with purpose and outcome, failed lives included (§7.4).
- [ ] The bucket is either deleted or reduced to the artifacts you keep (results, final light weights, logs). Full
      resume states go.
- [ ] Budgets: delete per-project budgets you no longer need. Keep the account-wide one.
- [ ] If the project is finished, unlink it from the billing account to free a slot.

## Local watchers
- [ ] No proxy is listening on the endpoint port (both proxy processes are gone, §5.2).
- [ ] Launchers, followers, nightwatches, swap scripts and timers are stopped (`kill $(cat <pidfile>)`).
- [ ] The launchd supervisor and launcher agents are removed: `launchctl bootout gui/$(id -u)/<label>`, then delete
      the plists. An unloaded plist left in `~/Library/LaunchAgents` restarts the dead run at the next login (§4.11).
- [ ] The run is marked finished in the ledger, so tier 2 stops expecting check-ins (§4.1).

## Laptop
- [ ] Model caches for this project are cleaned.
- [ ] Downloaded checkpoints and raw datasets are off the laptop.
- [ ] No token was written into the repo, the bucket or VM metadata.
