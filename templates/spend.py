"""Estimated GPU-VM spend for a project from GCP's operation log (insert -> delete/preempted; running = until now).

  python3 templates/spend.py        # one line per VM life + total (the launcher reads the last line)
Estimate, not invoice: disk and bucket cents are excluded.
Get RATE from the Cloud Billing Catalog API, not from memory.
"""
import datetime as dt
import json
import subprocess
import sys

# ======================== PLACEHOLDERS — edit these ========================
PROJECT = "<gcp-project-id>"
# $/h per region for your spot machine type: GPU + vCPUs + RAM, each from the billing catalog.
# Worked example (catalog read September 2026): spot a2-ultragpu-1g (1x A100 80GB, 12 vCPU, 170 GB):
#   "us-east5": 1.3027 + 12 * 0.01844 + 170 * 0.00247  (~1.94)
RATE = {"<region>": 0.0}
# ===========================================================================
if PROJECT.startswith("<") or "<region>" in RATE:
    sys.exit("fill the placeholders at the top of spend.py first")


def lives():
    out = subprocess.run(["gcloud", "compute", "operations", "list", "--project", PROJECT, "--format", "json",
                          "--filter", "operationType:(insert OR delete OR compute.instances.preempted) AND targetLink~instances"],
                         capture_output=True, text=True, check=True).stdout
    open_, rows = {}, []
    for o in sorted(json.loads(out), key=lambda o: o["insertTime"]):
        key = (o["targetLink"].rsplit("/", 1)[1], o["zone"].rsplit("/", 1)[1])
        t = dt.datetime.fromisoformat(o.get("endTime") or o["insertTime"])
        if o["operationType"] == "insert":
            if o.get("error"):
                continue  # failed create (no capacity): never ran, never billed
            open_[key] = t
        elif key in open_:
            rows.append((*key, open_.pop(key), t, o["operationType"].rsplit(".", 1)[-1]))
    now = dt.datetime.now(dt.timezone.utc)
    rows += [(*k, s, now, "RUNNING") for k, s in open_.items()]
    return rows


def rate(zone: str) -> float:
    # A region missing from RATE is charged the highest known rate: an unknown region must not stop the cap counting.
    return RATE.get(zone.rsplit("-", 1)[0], max(RATE.values()))


def total() -> float:
    return sum((e - s).total_seconds() / 3600 * rate(z) for _, z, s, e, _ in lives())


if __name__ == "__main__":
    for n, z, s, e, how in lives():  # times in local time
        h = (e - s).total_seconds() / 3600
        print(f"{n} {z} {s.astimezone():%m-%d %H:%M}-{e.astimezone():%H:%M} {h * 60:6.1f} min {how:9s} "
              f"${h * rate(z):.2f}")
    print(f"TOTAL ${total():.2f}")
