# Beanstalk worker, SQS queue and cron — READ-ONLY

SWS only. Read when the Beanstalk worker, its SQS queue or cron misbehaves.
Verified against `sws-6@0719a1faa0` (origin/master) and AWS `546532984119` on 2026-10-23.

Read this when https://starwebserver.se/app/status/cron warns (`Last cron job ran … minutes
ago`), when `sws6-production-worker` goes Yellow/Red, when the `sws6-production` SQS backlog
grows, or when queued jobs (order emails, ES indexing, Fortnox/Hogia/Ongoing syncs, reports)
are late. Everything here is read-only on the default low-priv profile; the general rules,
auth and the ES/Grafana/proxy recipes are in `prod-observability.md`.

## How the pieces fit

- **One queue, everything on it.** `sws6-production-worker` (c5.large, min 1 / max 2, ASG
  `awseb-e-mfsrhccbha-stack-AWSEBAutoScalingGroup-h5QCOqCoAfdl`) consumes SQS
  `sws6-production` through sqsd: `HttpConnections=5` per instance, `VisibilityTimeout=3600`,
  `InactivityTimeout=1800`, `ErrorVisibilityTimeout=120`, `MaxRetries=50`. Bernard jobs go to
  `/app/beanstalk-worker/consume-queue`; cron ticks from `cron.yaml` (sws-6
  `resources/deploy-config-docker/eb-version/cron.yaml`) are **messages on the same queue**
  posted to `/app/beanstalk-worker/consume-cron`. Anything that floods the queue delays
  cron too — there is no priority lane.
- **The status page is a log check, not a health check.** `StatusController::cronAction`
  reads the newest line of the `app-cron.log` stream in `/starweb/sws/starwebserver.se` and
  warns when it is older than 20 min. It says nothing about why.
- **Worker vs web in CloudWatch.** The main group's streams (`app-cron.log`,
  `app-general.log`, `app-error.log`, `app-api.log`, `db-migrations`, `klarna-kco*.log`,
  `svea-sco.log`, `shop-hogia-retail`) are shared by all instances; only `app-cron.log` is
  worker-only. Per-instance (`i-…`) streams exist only in the sub-groups
  (`…/que-messages`, `…/shop-fortnox`, `…/ongoing`, `…/shop-api-v2`, `…/klarna-kco3`,
  `…/qliro-checkout`, `…/nets`, `…/postnord`, `…/svea-sco`, `…/wasa-checkout`,
  `…/rule-marketing`, `…/session_errors`, `…/shop-csp-violation`, `…/oauth-server`).
  `/aws/elasticbeanstalk/sws6-*` groups hold deploy-time engine logs only — don't query them.
- **Two Aurora clusters.** Shops are spread over `sws-6-1-aurora-instance-4` and
  `sws-6-2-aurora-instance-4` (both db.r6g.2xlarge, writer-only, Performance Insights on).
  One shop's heavy job pins only its cluster; the other stays normal. Each shop has its own
  random-looking DB user, so PI's top `db.user` identifies a shop without naming it.

## Diagnosis order (10 minutes, all read-only)

Run the first three together — they decide whether the worker is starved, stuck or dead.

```bash
export AWS_REGION=eu-central-1
aws elasticbeanstalk describe-environment-health --environment-name sws6-production-worker --attribute-names All
aws elasticbeanstalk describe-instances-health   --environment-name sws6-production-worker --attribute-names All
aws elasticbeanstalk describe-events --environment-name sws6-production-worker \
  --start-time "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)" --max-items 60
```

Then the queue, worker CPU and both Aurora writers for the last 3 h (`get-metric-data`,
period 300; sort timestamps — they arrive newest-first):

| Metric | Read it as |
|---|---|
| SQS `ApproximateNumberOfMessagesVisible` rising while `NumberOfMessagesDeleted` per 5 min drops | consumption collapsed, not an inflow spike |
| SQS `ApproximateNumberOfMessagesNotVisible` flat at **10–12** | all 2×5 sqsd connections busy — the worker is saturated |
| SQS `NumberOfEmptyReceives` = 0 | queue never empty since |
| Worker ASG `CPUUtilization` flat ≈ 2% while in-flight is 10–12 | jobs are I/O-blocked (DB, external API), not CPU-bound |
| `AWS/RDS CPUUtilization` on one writer ≈ 99% and `SelectLatency` ×10 | that cluster is the bottleneck |
| `AWS/ES ThreadpoolSearchQueue` > 700 instead | ES is the bottleneck (see prod-observability.md) |

Instance count on the worker = `CPUUtilization` SampleCount / 5 (1-min monitoring, no group
metrics). Health `RequestCount: 0` on worker instances is normal (sqsd traffic isn't counted).

### Find the job

1. **Last cron activity** — Logs Insights on `/starweb/sws/starwebserver.se`:
   `fields @timestamp, @message | filter @logStream = 'app-cron.log' | sort @timestamp desc | limit 60`.
   The newest `ended in …` line is the status page's timestamp (in-body CEST, `@timestamp` UTC).
2. **What the worker was doing when it froze** — `app-general.log` by logger:
   `filter @logStream = 'app-general.log' | parse @message /\] \[(?<logger>[^\]]+)\] (?<level>[A-Z]+): / | stats count() by logger, level | sort count desc`
   over the 15 min before the freeze; then read the newest 60 lines of that window. If
   `AWS/ES IndexingRate` is up while `addProductToElasticsearchJob` lines/min stay flat, the
   writer is not on the worker — see the write-storm signature in `prod-observability.md`.
3. **Who hammers the DB** — Performance Insights works on the low-priv role:

```bash
RID=$(aws rds describe-db-instances --db-instance-identifier sws-6-2-aurora-instance-4 \
      --query 'DBInstances[0].DbiResourceId' --output text)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ); START=$(date -u -d '45 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
for G in db.sql_tokenized db.user db.host db.wait_event; do
  aws pi describe-dimension-keys --service-type RDS --identifier "$RID" --metric db.load.avg \
    --group-by "{\"Group\":\"$G\",\"Limit\":8}" --start-time "$START" --end-time "$END" --period-in-seconds 300
done
# full statement text with literals and the route comment — db.sql only (db.sql_tokenized is refused):
aws pi describe-dimension-keys --service-type RDS --identifier "$RID" --metric db.load.avg \
  --group-by '{"Group":"db.sql","Limit":5}' --start-time "$START" --end-time "$END" --period-in-seconds 300
aws pi get-dimension-key-details --service-type RDS --identifier "$RID" --group db.sql \
  --group-identifier <db.sql.id> --requested-dimensions statement
```

   `db.host` values are private IPs — map them with
   `aws ec2 describe-instances --filters Name=tag:elasticbeanstalk:environment-name,Values=sws6-production-worker,sws6-production`
   (prints instance id, IP, env). `db.sql` statements carry a comment
   `/* rid='…',route='queue%3AgenerateReport' */` — the route names the job
   (`queue:<jobName>`) or the admin controller route. `db.load.avg` totals near 8–9 on a
   2xlarge (8 vCPU) mean the instance is pinned.
4. **What is queued** — `aws sqs receive-message --queue-url https://sqs.eu-central-1.amazonaws.com/546532984119/sws6-production --max-number-of-messages 10 --visibility-timeout 1 --attribute-names All --message-attribute-names All`.
   Body `{"args":{"name":"<job>",…}}`; cron ticks have message attribute
   `beanstalk.sqsd.task_name`. **Head-biased:** SQS returns the oldest messages, so a sample
   that is 100 % one job type says nothing about the backlog mix — estimate the mix from
   `NumberOfMessagesSent` per 5 min around the burst instead.
5. **Job-specific progress** — sales reports (`generateReport`) write to
   `s3://starweb-static-production/data/shops/<shop-id-code>/reports/<hash>/`: `metadata`
   (PHP-serialized; `total_amount_of_pages`, `total_amount_of_orders`, `email_address`) and
   one `page_NNNN` per finished page. `aws s3 ls … | grep -c page_` is the progress counter
   and the `Generated sales report data … (page N)` log lines give the rate.

## Read the result

- **Starved, not stuck:** in-flight pinned at 10–12, deletes still ~150–180 per 5 min,
  pages/jobs still completing, DB pinned → one job family is hogging every connection. It
  self-heals when that family drains; estimate `remaining / rate`. Cron ticks queued during
  the starvation run late but do run (cron commands carry an "already running" lock).
- **Stuck:** in-flight 10–12, deletes ≈ 0, no new log lines from any job → hung HTTP calls
  or DB locks (`RowLockTime`, `BlockedTransactions`, `Deadlocks` on the writer). A message
  held for exactly 3600 s and then reappearing (`ApproximateAgeOfOldestMessage` climbing to
  ~3400 with visible = 0, then resetting) is one hung job cycling through its visibility
  timeout — not a backlog.
- **Dead:** in-flight 0, visible rising, instances Degraded/NoData → instance or deploy
  problem; read `describe-events` and instance health.

## What not to do

- Don't scale the worker (`MaxSize` 2) when a DB is at 99 %: more connections make the
  cluster — and every web request for the shops on it — slower.
- Don't purge the queue to kill one job family: it drops every other shop's emails, indexing
  and cron ticks. SQS can't delete selectively.
- Don't kill DB sessions of a paged job: the page returns 5xx, sqsd re-queues it after 120 s,
  up to 50 times, and the load comes back.
- Don't read a Yellow `messages waiting in the queue` event as the cause — it is the symptom.

## Gotchas for the commands

- `aws logs start-query` needs epoch **seconds**; `@timestamp` filters inside the query
  need epoch **milliseconds** — compute them with `date -u -d '2026-10-07 09:10' +%s`,
  never by hand. A query over a wrong window returns 0 matches silently.
- `describe-log-groups` is paginated: a `| head` cuts the `/starweb/…` groups off the end —
  use `--log-group-name-prefix /starweb`.
- `get-metric-data` rejects duplicate `Id`s; derive ids from the full identifier, not a
  truncated prefix. Ids may only contain `[a-z][a-zA-Z0-9_]*`.
- `pi get-dimension-key-details` supports only `--group db.sql` on Aurora MySQL.
- `sqs receive-message --attribute-names` takes space-separated names or `All`; a
  comma-joined list is treated as one invalid name and the `Attributes` key is missing.
- `describe-configuration-settings` prints every env var in clear — redact values before
  showing them; only `APP_ENV`, `OAUTH_DYNAMODB_CLIENTS_TABLE`, `SHOP_API_NATIVE_AUTH_MODE`
  are safe to echo.
- The sws-6 repo lives in `~/code/sws-6`; shell cwd resets between calls, so use absolute
  paths (`cd /home/user/code/sws-6 && …`).
- Sentry needs a valid token in `~/.tokens/sentry` (`{"detail":"Invalid token"}` = expired;
  rotation is user-only, see `../tokens.md`). Grafana is not needed for this path.
- A large DLQ means something failed within its 14-day retention, not necessarily now —
  date the messages (`SentTimestamp` from `--attribute-names All`) before linking them to
  today's symptom.

## Incident signatures

- **2026-10-07 starved (sales-report fan-out):** in-flight 10–12, deletes 150–180 per 5 min,
  worker CPU 2 %, one Aurora writer at 99 % with PI `db.user` = one shop user, backlog > 8k,
  every other job 45–60 min late. Cause: one `OrderSummaryByDay` report over 86k orders fanned
  out 1,726 `generateReport` pages, each re-running the filtered `COUNT(*)`. The
  `OrderItemsDiscountMerger … cannot be merged` errors alongside are per-order validation noise.
  Fixed by THE-24659 (pages by id). Still open: cap report-page concurrency; alarm on
  `ApproximateAgeOfOldestMessage` with visible > 0 instead of cron freshness.
