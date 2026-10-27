# Prod observability — READ-ONLY

SWS only. Read before querying any SWS production or staging signal source.
Verified against AWS `546532984119`, Grafana Cloud, Sentry and `reverse-proxy@59a523b` on 2026-10-27.

Everything in this file is read-only access. **Ask before any write**, including touching
the `prod-admin` / `prod-pulumi` AWS profiles. **Token minting/rotation is user-only —
never do it yourself; guide the user** (`../tokens.md`).

- Grafana: `/api/v1/query`, `/api/v1/query_range`, `/api/v1/label/...`, `/api/v1/series`
  only. Never remote-write (`/api/prom/push`), never delete series.
- AWS: `cloudwatch list-metrics|get-metric-data|get-metric-statistics`, Logs Insights,
  non-deleting `sqs receive-message` — on the default low-priv profile only.
- Prod ES API: **no access — never query it directly** (read/write can't be gated
  separately). Hand read-only queries to the user to run instead; see the ES internals
  section. ES *metrics* via CloudWatch are fine.

`sws-api` (the former Kubernetes service) is discontinued and integrated into the `sws-6` main
codebase; its errors and access logs are found the same way as any other sws-6 errors and logs below.

## Where to look

| Signal | Source |
|---|---|
| SQS queues | CloudWatch `AWS/SQS` — Grafana's `aws_sqs_*` scrape is **dead since mid-Aug 2026** |
| Elasticsearch (prod) / OpenSearch (staging) | CloudWatch `AWS/ES` — Grafana has 8 of ~150 metrics, dashboards only |
| ES cluster internals (shards, thread pools) | ES API — **user-run only**, hand over query batches |
| Beanstalk web/worker CPU + instance counts | CloudWatch `AWS/EC2`; worker/queue/cron diagnosis in `worker-queue-cron.md` |
| App logs, ES-domain logs, proxy container logs | CloudWatch Logs Insights |
| Proxy **access** logs (not in CloudWatch at all) | S3 `reverse-proxy-nginx-logs` |
| App errors / exceptions | Sentry |
| Kubernetes `k8s-prod` (not SWS), ES/RDS/ECS CloudWatch integrations | Grafana Cloud |

---

## Grafana Cloud (Prometheus/Mimir)

**Access:** `https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom`
(stack `starweb`, `mimir-prod-24`, data in AWS `eu-central-1`).
**Auth:** HTTP basic, instance ID `1181702` + `GRAFANA_CLOUD_TOKEN` from
`~/.tokens/grafanacloud`. Never echo the token or put it in a file/URL/commit.
On `401`: token expired — minting is **user-only, never do it yourself**: guide the user
to <https://starweb.grafana.net/a/grafana-auth-app> (read scopes only) and have them
update the env file (ID stays `1181702`). Details: `../tokens.md`.

Nothing SWS-specific is scraped here: the only cluster is `k8s-prod` and the AWS integration
jobs (`…-AWS-ES-…`, `…-rds-metrics-…`, `…-ECS-ContainerInsights-…`) carry a thin copy of
CloudWatch. Use it for cross-service dashboards, not for SWS diagnosis.

**Query:**

```bash
set -a; . ~/.tokens/grafanacloud; set +a
PROM=https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom
AUTH=(-u "1181702:$GRAFANA_CLOUD_TOKEN")

curl -s "${AUTH[@]}" --get "$PROM/api/v1/query" --data-urlencode 'query=<promql>'
curl -s "${AUTH[@]}" --get "$PROM/api/v1/query_range" \
  --data-urlencode 'query=<promql>' \
  --data-urlencode "start=$(( $(date -u +%s) - 21600 ))" \
  --data-urlencode "end=$(date -u +%s)" --data-urlencode 'step=300'
curl -s "${AUTH[@]}" "$PROM/api/v1/label/__name__/values"   # discovery, ~790 names
curl -s "${AUTH[@]}" --get "$PROM/api/v1/query" --data-urlencode 'query=count by (job) (up)'  # which scrape jobs exist
```

**Gotchas:**
- CloudWatch-sourced series lag ~5 min. All timestamps UTC — use `date -u`.
- `aws_sqs_*` series names still exist (`aws_sqs_info` answers) but carry no data points.

---

## SQS — CloudWatch `AWS/SQS`

**Access:** namespace `AWS/SQS`, dimension `QueueName`. Queues: `sws6-production` and
`sws6-production-dead-letter-queue` (redrive maxReceiveCount 5, retention 14 d).
Account `546532984119`, region `eu-central-1`.
**Auth:** default AWS profile (see ES section).

**Gotchas:**
- Grafana's `aws_sqs_*` scrape is dead since mid-Aug 2026 — `aws_sqs_info` still answers,
  don't be fooled. Always query CloudWatch.
- DLQ redrive does **not** increment `NumberOfMessagesSent` — watch the DLQ's
  `ApproximateNumberOfMessagesVisible`.
- `ApproximateAgeOfOldestMessage` can read 2000–3500 s while messages-visible is 0
  (stuck in-flight message, not real backlog). Never alert on age alone; require visible > 0.
- DLQ inspection without deleting: `aws sqs receive-message --visibility-timeout N`
  (messages reappear after N s). Bodies are Bernard JSON (`{"args":{"name":"<job>",…}}`);
  body `elasticbeanstalk scheduled job` = worker cron tick — task name is in message
  attribute `beanstalk.sqsd.task_name`.
- A large DLQ means something failed within the 14-day retention window, not necessarily
  now — date the messages (`SentTimestamp`, `--attribute-names All`) before linking them to
  today's symptom.

---

## Elasticsearch / OpenSearch — CloudWatch `AWS/ES`

**Access:** account `546532984119`, region `eu-central-1`. Domains:
prod `sws-production-74` (Elasticsearch, 4 data nodes) · staging `sws-staging-74-new`
(OpenSearch, 1 data node). Never diagnose these from Grafana — its copy omits every
indexing, thread-pool, storage and HTTP-status metric.
**Auth:** default profile assumes `SebastianLockwoodLowPriv` (verify:
`aws sts get-caller-identity`); `export AWS_REGION=eu-central-1`. Never use
`prod-admin`/`prod-pulumi` for metrics; ask before using them at all.

**Query** — batch template (`get-metric-data`, up to 500 metrics/call):

```bash
DOM=sws-production-74   # or sws-staging-74-new
python3 - > /tmp/mdq.json <<EOF
import json
D=[{"Name":"ClientId","Value":"546532984119"},{"Name":"DomainName","Value":"$DOM"}]
specs=[("il","IndexingLatency","Average"),("ilmax","IndexingLatency","Maximum"),
 ("ir","IndexingRate","Average"),("twq","ThreadpoolWriteQueue","Maximum"),
 ("twr","ThreadpoolWriteRejected","Maximum"),("cwr","CoordinatingWriteRejected","Maximum"),
 ("pwr","PrimaryWriteRejected","Maximum"),("rwr","ReplicaWriteRejected","Maximum"),
 ("tsq","ThreadpoolSearchQueue","Maximum"),("tsr","ThreadpoolSearchRejected","Maximum"),
 ("ciwb","ClusterIndexWritesBlocked","Maximum"),("fss","FreeStorageSpace","Minimum"),
 ("dqd","DiskQueueDepth","Maximum"),("sl","SearchLatency","Average"),
 ("slmax","SearchLatency","Maximum"),("cpu","CPUUtilization","Maximum"),
 ("jvm","JVMMemoryPressure","Maximum")]
print(json.dumps([{"Id":i,"MetricStat":{"Metric":{"Namespace":"AWS/ES","MetricName":m,
 "Dimensions":D},"Period":300,"Stat":s}} for i,m,s in specs]))   # Period 60 works — use it for an alarm window
EOF
aws cloudwatch get-metric-data --region eu-central-1 \
  --start-time "$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --metric-data-queries file:///tmp/mdq.json --output json
```

Discovery: `aws cloudwatch list-metrics --namespace AWS/ES ...` (metric names, dimension sets).

**Gotchas:**
- **Node/domain trap:** `ClientId`+`DomainName` = domain aggregate; +`NodeId` = per data
  node. Averages and latencies cannot be rebuilt from node series. `IndexingRate`/`SearchRate`
  with `Sum` do add up (replica ops count on their node), so a 10× jump on exactly two nodes
  = one shard's primary + replica.
- Prod node IDs: `-DaP05VUSqeDWIPMYA5Mdw`, `Q8tgjPC3QHaeACyfzDNAKQ`, `eNWAI04ES2ueiOIbf3euCw`,
  `q46Os8YPSXO38q9XTafOAA`. Quote `-DaP05…` — the leading dash parses as a flag.
- **`get-metric-data` returns timestamps NEWEST-FIRST** — sort before computing deltas, or
  every trend's sign flips. Timestamps arrive in local tz offset; normalise to UTC.
- `Threadpool*Rejected` are **cumulative counters since node start** — always diff
  consecutive points, and read with stat `Maximum` (not `Sum`).

**Thresholds:**

| Metric | Healthy | Bad |
|---|---|---|
| `ThreadpoolSearchQueue` | < 200 | > 700 (queue limit 1000; rejections at the cap) |
| `ThreadpoolSearchRejected` delta | 0 | any sustained increase = dropped queries |
| `CPUUtilization` | < 80% | > 90% sustained |
| `SearchLatency` avg | ~26–50 ms | > 90 ms |
| `ThreadpoolWriteQueue` | ~0–1 | growing |
| write-reject deltas (all four) | 0 | any |
| `ClusterIndexWritesBlocked` | 0 | 1 = writes rejected outright |
| `FreeStorageSpace` | well above 20 GB (≈19.8 GB min on 2026-10-23 — at the line) | near low-watermark ⇒ ES blocks writes |
| `IndexingRate` (Sum/min) | ≈ 2× the worker's "Adding product" lines/min (P+R); `IndexingLatency` single-digit ms | 10× on one shard's two nodes, CPU 99 % there, search queue low, no rejections ⇒ **write storm**: find the writer (Logs + access-log recipes below), don't restart the node the alarm text names |

Also published (and absent from Grafana): `ShardCount`, `Shards.active`, `2xx/4xx/5xx`,
`JVMGCOldCollectionTime`, `SysMemoryUtilization`, `OpenContexts`, `ThreadpoolSearchThreads`,
`WriteLatency`, `ReadLatency`, `BurstBalance`, `MasterJVMMemoryPressure`.

**Correlation rule:** the Beanstalk worker queries this domain, so ES search saturation
shows up as SQS backlog growth while the worker sits near-idle (I/O-blocked). Worker ASG CPU
≈ 2 % + search queue > 700 + rising backlog ⇒ **ES search capacity is the constraint** —
scaling the worker won't help and adds load (`worker-queue-cron.md`).

---

## ES cluster internals — ES API (NO AI ACCESS — user-run only)

**Access:** **Claude has no access to prod Elasticsearch and must never query it** — the
endpoint cannot gate read from write access separately. Instead, and only when directly
relevant to the troubleshooting at hand, write the read-only (GET-only) queries as one
larger copy-pastable batch for the user to run manually (VPN) and paste the output back.
ES *metrics* are still safe to fetch yourself via CloudWatch `AWS/ES` (section above).

Endpoint (for the batches):
`https://search-sws-production-74-kc4urq6grrqkotg37i5kusqogm.eu-central-1.es.amazonaws.com`
(ES 7.9 OSS). 4 data nodes + 3 dedicated masters. Main index **shops_v11**
(last seen 2026-08-31; the user confirms the current name): 2 primaries × 1 replica,
~15 GB primary / ~31 GB total, one shard copy per data node.

**Query** (template for user-run batches):

```bash
ES=https://search-sws-production-74-...  # see above
curl -s "$ES/_cat/indices/shops_v11?v&h=index,health,pri,rep,docs.count,store.size,pri.store.size"
curl -s "$ES/_cat/shards/shops_v11?v&h=shard,prirep,state,store,node"
curl -s "$ES/_cat/nodes?full_id=true&h=id,name,node.role"   # full_id ⇒ id == CloudWatch NodeId
curl -s "$ES/_stats/search?level=shards&pretty"             # per-shard-copy query counters
curl -s "$ES/_cat/thread_pool/search?v&h=node_name,active,queue,rejected"
```

Rule out a manual `es:bulk-reindex` (console-only output, nothing in CloudWatch) yourself:
`aws ssm describe-sessions --state History --filters key=InvokedAfter,value=<ISO>` (low-priv OK).

Node map (2026-08-31; the CloudWatch NodeIds are unchanged on 2026-10-23 — re-derive the
shard column with the two `_cat` commands if AWS replaces a node):

| ES node | CW NodeId | Holds |
|---|---|---|
| d6f9897e… | `-DaP05VUSqeDWIPMYA5Mdw` | shard 0 primary |
| d75abf19… | `eNWAI04ES2ueiOIbf3euCw` | shard 0 replica |
| e7fde58b… | `q46Os8YPSXO38q9XTafOAA` | shard 1 primary |
| 0e2d17b3… | `Q8tgjPC3QHaeACyfzDNAKQ` | shard 1 replica |

**Gotchas:**
- **Shard 0 serves ~2× shard 1's queries** (per-shop routing; hot shops hash to shard 0) —
  its nodes saturate first. Data-layout issue, not placement.
- On 4 data nodes rep=1 and rep=3 are even; **rep=2 is never OK** (6 copies / 4 nodes).
  Primary-count changes need a reindex — plan 4 primaries at the next index version.
- Adaptive replica selection avoids cold/young replicas — a copy can look "dead" in the
  counters; diff `_stats/search?level=shards` over minutes before assuming pinning.
- `search.query_total` values are counters since node/shard start — always diff.
- Disk: ~27 GB usable/node, `FreeStorageSpace` sits at the 20 GB comfort line;
  reindex-in-place temporarily doubles used space.

---

## Beanstalk web/worker — CloudWatch `AWS/EC2`

**Access:** envs `sws6-production` (web, `e-m5mpqmrsgz`, behind the reverse proxy) and
`sws6-production-worker` (`e-mfsrhccbha`). CPU/instances via `CPUUtilization` with the
`AutoScalingGroupName` dimension.

**Query:** `CPUUtilization` by `InstanceId` for per-instance CPU. Web instance IDs are the
per-instance stream names in the sub-groups (`…/shop-api-v2`, `…/nets`, …); worker IDs come
from `describe-auto-scaling-groups` on the ASG below. A name grep for "production" misses
the web ASG — awseb ASG names carry only the env ID.

**Gotchas:**
- Web ASG: `awseb-e-m5mpqmrsgz-stack-AWSEBAutoScalingGroup-UkGGt5Rvdn6T` (unchanged since
  2026-08-31). **Immutable deploys/rebuilds rotate the ASG name** and leave
  `awseb-e-<envid>-immutable-stack-…` siblings in `list-metrics` for two weeks — sweep all
  awseb ASGs by SampleCount to find who carried traffic in a past window.
- **Instance count = CPUUtilization SampleCount / (period/60)** (1-min detailed monitoring
  on). No GroupInServiceInstances — group metrics aren't enabled on awseb ASGs.
- Scale-in trigger: 35% avg CPU lower bound; equilibrium sits just above it — expected
  instances ≈ (avgCPU% × instances) / 35. July 2026 baseline: ~8.3 instances @ ~42.5% CPU
  (6–11 diurnal). Avg CPU far below 35% for hours ⇒ scale-in pinned (raised min, suspended
  process) — check env capacity config.

---

## Logs — CloudWatch Logs Insights

**Access:** `aws logs start-query` / `get-query-results` on the low-priv role.

| What | Log group |
|---|---|
| SWS prod app logs (live) | `/starweb/sws/starwebserver.se` (streams `app-general.log`, `app-error.log`, `app-api.log`, `app-cron.log`, …) + sub-groups `…/que-messages`, `…/shop-api-v2`, `…/shop-fortnox`, `…/ongoing`, `…/klarna-kco3`, `…/qliro-checkout`, … (`describe-log-groups --log-group-name-prefix /starweb/sws`) |
| SWS staging | `/starweb/sws/sws-staging.se` + the same sub-groups |
| Who writes to ES | worker product jobs log `[addProductToElasticsearchJob] Adding product` in `app-general.log`; `EsRelatedChangeHandler` (pricelist create, stock-location, VAT delete, attribute, manufacturer, review) rewrites the **whole shop inline in the web request**, scroll size 10, logs nothing, keeps running after the client disconnects; only the tag/tag-option updaters log, to `…/que-messages` ("Processed N/M products for tag option X") |
| ES domain logs | `/aws/aes/domains/sws-production-74/application-logs` — DEBUG `TransportSearchAction` noise + "Result window is too large" (clients paging past 10k); says nothing about writes |
| Reverse proxy container logs — **no access logs** (those are S3-only, see below) | `/ecs/reverse-proxy`, `/ecs/reverse-proxy-https`, `…-log-shipper`, `…-crowdsec-appsec` |
| `/aws/elasticbeanstalk/sws6-*` | deploy-time engine logs only (`eb-engine.log` on each deploy), no app logs — don't use for troubleshooting |

**Gotchas:**
- App log messages carry **CEST timestamps in-body**; Insights `@timestamp` is UTC.
- ES writes per shop per 5 min: `filter @logStream = "app-general.log" and @message like /addProductToElasticsearchJob/ | parse @message /"shopIdCode":"(?<shop>[^"]+)"/ | stats count() as n by bin(5m) as b, shop | sort b asc`
- Whole family at a glance: `start-query --log-group-names <all /starweb/sws/starwebserver.se* groups>` with `stats count() as n by @log, @logStream | sort n desc`.
- Insights rejects `sort bin(5m)` and `sort count desc` — alias first (`as b`, `as n`), then sort the alias.

---

## Proxy access logs — S3 only (not in CloudWatch at all)

**Access:** bucket `reverse-proxy-nginx-logs` — the only place access logs exist; the
`/ecs/reverse-proxy*` CloudWatch groups carry container logs, not access logs.
- Raw per-minute (UTC paths): `nginx-logs/reverse-proxy/YYYY/MM/DD/HH/MM/<task-uuid>/log-shipper/access-object<rand>`
  (+ small `error-object*` siblings) — ~45–75 gzip objects/min **without a .gz extension**.
- Daily compacted: `compacted/reverse-proxy/YYYY/MM/DD/access.log.gz` (~1.3 GB/day).
  **The current day is never compacted yet** — use the raw per-minute prefixes for today.
- `reverse-proxy-athena-results` bucket exists for Athena over these logs.

**Recent window (e.g. last 15 min)** — verified 2026-10-23: ~700 files / ~310k lines, ~30 s
wall with parallel per-minute `cp` (small enough to run in the foreground):

```bash
DEST=~/.cache/proxy-logs/$(date -u +%Y%m%dT%H%M)-last15 && mkdir -p "$DEST"
for i in $(seq 16 -1 2); do   # skip the newest 2 min — objects land up to ~65 s late
  ts=$(date -u -d "-$i minutes" +%Y/%m/%d/%H/%M)
  aws s3 cp --recursive "s3://reverse-proxy-nginx-logs/nginx-logs/reverse-proxy/$ts/" \
    "$DEST/${ts//\//}/" --exclude "*" --include "*access-object*" --only-show-errors &
done; wait
find "$DEST" -name 'access-object*' -exec cat {} + | gzip -dc > "$DEST/access.log"
```

Always land in a fresh dated subdir under `~/.cache/proxy-logs/` (as above) — never mix the
thousands of small objects into an existing dir. Concatenated gzip members decompress with
a single `gzip -dc`; lines are unordered across tasks/minutes — sort on field 5 (`[ts`) if
order matters. A minute prefix spills a few seconds into the next minute.

**Freshness:** the result trails "now" by ~2–3 min — ~1 min log-shipper push lag (hence the
2 skipped minutes) plus the download. Don't read the empty tail as traffic stopping,
and when correlating with CloudWatch remember its metrics are also ~1 min+ behind (ES/SQS
integration series in Grafana ~5 min).

### Debugging the search endpoint

Block rules live in the reverse-proxy repo: `conf.d/invalid_reqest_handler` (enforcement).
The junk-search pattern file (`block_junk_search.conf` in the 2026-08-31 incident) is **not**
in `reverse-proxy@59a523b` `conf.d/` — ask the user where the current patterns live (S3-synced
vhost config or CrowdSec AppSec) before pointing at a path. Field map for the merged log —
split on `"`: `$2`=request, `$3`=` status bytes `, `$6`=UA; split on whitespace: `$1`=vhost,
`$2`=client_ip, `$5`=`[ts`. With `D=~/.cache/proxy-logs/<stamp>-last15`:

```bash
awk -F'"' '$2 ~ /^[A-Z]+ \/search/' $D/access.log > $D/search.log    # all search traffic

# status spread — 403 = block firing; 499 = client aborts (mostly autocomplete keystrokes)
awk -F'"' '{split($3,a," "); print a[1]}' $D/search.log | sort | uniq -c | sort -rn

# block evasion: junk patterns that did NOT get 403 — must print nothing
awk -F'"' '{split($3,a," "); if(a[1]!=403 && $2 ~ /(%3B|%253B|;)amp|amp(%3B|%253B|;)|page=[0-9]+.*[?&].*page=[0-9]+/) print}' $D/search.log

# who hits plain /search (non-403): top client IPs, then top UAs
awk -F'"' '{split($3,a," "); if(a[1]!=403 && $2 !~ /get-autocomplete/) print $1}' $D/search.log | awk '{print $2}' | sort | uniq -c | sort -rn | head
awk -F'"' '{split($3,a," "); if(a[1]!=403 && $2 !~ /get-autocomplete/) print $6}' $D/search.log | sort | uniq -c | sort -rn | head

# heaviest queries by upstream time — match rt= as a whole field (a bare regex also hits uct=)
awk -F'"' '{split($3,a," "); if(a[1]==200 && $2 !~ /get-autocomplete/){n=split($0,f," "); for(i=1;i<=n;i++) if(f[i] ~ /^rt=/){print substr(f[i],4), $2; break}}}' $D/search.log | sort -rn | head

# who writes: write methods per minute by vhost, status, path prefix — compare a baseline minute with the first burst minute
grep -E '"(POST|PUT|PATCH|DELETE) ' $D/access.log | awk -F'"' '{split($3,a," "); split($2,r," "); split(r[2],p,"/"); split($1,h," "); print h[1], a[1], r[1], "/"p[2]"/"p[3]}' | sort | uniq -c | sort -rn | head -20

# long or aborted requests (rt ≥ 30 s, or 499): the line is written when the request ENDS
awk '{for(i=1;i<=NF;i++) if($i ~ /^rt=/){if(substr($i,4)+0>=30) print; break}}' $D/access.log | head
```

Reading the results:
- **Distributed-crawler fingerprint:** ~1–2 reqs/IP across dozens of IPs, implausible
  Chrome-version spread in the UAs, deep `/search?m=…&page=N` pagination. Per-IP rate
  limits are useless against it — pattern or page-cap blocks are the lever.
- **Self-identifying crawlers** (UA token, e.g. `GeedoShopProductFinder`) may sit in a
  single /24 — compare `grep -c '<token>'` with `grep -cE '^[^ ]+ <prefix>\.'`; if equal,
  a CIDR limit is enough.
- **A long request lands in a later minute than it started.** `499` with a round `rt`
  (30, 100) is the client's own timeout — PHP keeps running, and a retry starts a second copy.

**Gotchas:**
- `/tmp` is a 1 GB tmpfs — download to `~/.cache/`. Never delete cached downloads unprompted — ask.
- **Don't stream/grep the download.** Anything bigger than the recent-window recipe runs as a
  background `aws s3 cp` to `~/.cache/`; grep the local file once it lands.
- Line format: `vhost client_ip - - [ts +0000] "METHOD /path" status bytes "referer" "UA" rt=… uct=… up_ip=… tls=…`
- **Timezone: everything here is UTC** — S3 paths and in-line timestamps (`+0000`) alike.
  But SWS app logs are **CEST in-body** (see Logs section): correlating access log ↔ app
  log naively puts events 2 h apart.

---

## Sentry

**Access:** org `starweb`, projects `sws-6` (prod PHP), `sws-6-staging`, `sws6-production-js`.
**Auth:** Bearer `SENTRY_TOKEN` from `~/.tokens/sentry`.

**Query:**
- Search issues: `GET https://sentry.io/api/0/organizations/starweb/issues/?query=<text>&statsPeriod=14d&sort=freq&limit=10`
- Latest event (tags incl. `shop` + stacktrace): `…/issues/<id>/events/latest/`

**Gotchas:** API can be slow — always `curl --max-time 30`.

---

## Incident signatures

- **2026-08-31 search saturation (scraper botnet):** `ThreadpoolSearchQueue` 872/958,
  `ThreadpoolSearchRejected` +1,170, CPU 90–99 % skewed to shard-0 nodes, write counters 0.
  Cause: distributed scraper looping junk `/search`; fixed with a proxy pattern block.
- **2026-10-27 write storm (inline pricelist reindex):** `IndexingRate` 1k → 12–19k/min on
  shard 0's two nodes only, CPU 99 % there, search queue ≤ 50, no rejections, worker/web CPU
  and app logs flat. Cause: one Shop API client `POST /api/v2/pricelists` ×9 (499 at 100 s,
  retried every 5 min; each run ≈ 30 min). Found via the access-log write histogram
  (baseline minute vs first burst minute) and the long/499 scan.
