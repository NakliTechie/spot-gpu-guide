# Pre-flight — before any code runs on a GPU

Do these on day one. Quota requests can take days. Source: GUIDE.md chapter 1.

## Account and billing
- [ ] The account is on a paid plan (GCP's Free Trial blocks GPUs; the trial credit survives the upgrade).
- [ ] You know when any credit expires.
- [ ] The billing account has a free project slot (GCP caps linked projects at 5).
- [ ] The project exists, is linked, and has the compute API enabled.

## Identity (GUIDE §1.5)
- [ ] A dedicated, scoped identity per project launches the jobs; no admin keys are used for launches.
- [ ] Only mutating actions are region-locked; destructive actions are gated on the `<project>=true` tag.
- [ ] A dry run with the scoped identity gets past the permission gate in every region you will use.
- [ ] Keys live in env or a secret store, never in the repo.

## Quota (GUIDE §1.1, §1.6)
- [ ] You read the project-wide and regional GPU quota for your target regions (on AWS, the G-family spot vCPU
      quota, per region).
- [ ] The design fits the quota you hold today (plan for 1 GPU on a new account). With 1 GPU, an eval VM waits for
      the training VM to be gone; a launcher that waits on a marker + no VM does that unattended.
- [ ] If you need more, the request or support case is filed now, not at launch.

## Regions and capacity (GUIDE §1.7, §1.8, §1.9)
- [ ] 3 or more regions are allowed, so the launcher can fail over when the cheapest one has no capacity.
- [ ] Each region's default route table sends `0.0.0.0/0` to an **active** gateway (AWS: not `blackhole`).
- [ ] Anything that calls the GPU workers per request (trainer, driver, proxy) runs in the same region as them.

## Budgets and the stop rule (GUIDE §1.3, §1.10)
- [ ] An **account-wide** budget exists. Per-project budgets do not see each other.
- [ ] The budget uses the billing currency, with credits **excluded**, so alerts track burn.
- [ ] A daily GPU-spend alert is scoped by instance family, so it catches untagged launches too.
- [ ] Cost-allocation tags are activated (they take about a day to populate).
- [ ] A written stop rule exists, for example: stop all GPU work at 90 % of the credit, across every project on the
      billing account. Alerts only email; they never stop spend.

## Prices
- [ ] Rates in `spend.py` come from the provider's catalog API for your machine type and regions, with the read date
      in a comment.

## Laptop (GUIDE chapter 6)
- [ ] Free disk is enough for code and logs only. Checkpoints stay in the bucket.
- [ ] Heavy local GPU work is off the plan; the rented GPU does the compute. If local GPU work is unavoidable, one job
      at a time under a machine-wide lock.
