# Prod observability — READ-ONLY

> **Unverified on the NEH workstation; last verified 2026-09-01** (date from the text itself) — see `../HANDOVER-sws.md`. SWS only. Read before querying any SWS production or staging signal source.

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

## Where to look

| Signal | Source |
|---|---|
| Kubernetes: pods, deployments, workers, nodes | Grafana Cloud |
| SQS queues | CloudWatch `AWS/SQS` — Grafana's `aws_sqs_*` scrape is **dead since mid-Aug 2026** |
| Elasticsearch (prod) / OpenSearch (staging) | CloudWatch `AWS/ES` — Grafana has 8 of ~150 metrics, dashboards only |
| ES cluster internals (shards, thread pools) | ES API — **user-run only**, hand over query batches |
| Beanstalk web/worker CPU + instance counts | CloudWatch `AWS/EC2` |
| App logs, ES-domain logs, proxy container logs | CloudWatch Logs Insights |
| Proxy **access** logs (not in CloudWatch at all) | S3 `reverse-proxy-nginx-logs` |
| App errors / exceptions | Sentry |

---

## Grafana Cloud (Prometheus/Mimir) — Kubernetes signals

**Access:** `https://prometheus-prod-24-prod-eu-west-2.grafana.net/api/prom`
(stack `starweb`, `mimir-prod-24`, data in AWS `eu-central-1`).
**Auth:** HTTP basic, instance ID `1181702` + `GRAFANA_CLOUD_TOKEN` from
`~/.tokens/grafanacloud`. Never echo the token or put it in a file/URL/commit.
On `401`: token expired — minting is **user-only, never do it yourself**: guide the user
to <https://starweb.grafana.net/a/grafana-auth-app> (read scopes only) and have them
update the env file (ID stays `1181702`). Details: `../tokens.md`.

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
curl -s "${AUTH[@]}" "$PROM/api/v1/label/__name__/values"   # discovery, ~747 names
```

**Gotchas:**
- `up` returns empty — not a health probe.
- CloudWatch-sourced series lag ~5 min. All timestamps UTC — use `date -u`.

### Key target: the SQS worker

Cluster `sws-api-production2`, ns `sws-api`, deployment `worker` (container `worker`).
Fixed **1 replica, no HPA** — the `app-hpa` (min 2/max 10) targets the API deployment.
Requests 0.5 CPU; limits 1 CPU / 1 GiB.

```promql
kube_deployment_spec_replicas{namespace="sws-api",deployment="worker"}
kube_deployment_status_replicas_available{namespace="sws-api",deployment="worker"}
kube_pod_container_status_restarts_total{namespace="sws-api",pod=~"worker-.*"}
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="sws-api",container="worker"}[10m]))
sum by (pod) (container_memory_working_set_bytes{namespace="sws-api",container="worker"}) /1024/1024
```

- `kube_pod_container_status_ready` returns no data for these pods — use
  `kube_deployment_status_replicas_available`.

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
 "Dimensions":D},"Period":300,"Stat":s}} for i,m,s in specs]))
EOF
aws cloudwatch get-metric-data --region eu-central-1 \
  --start-time "$(date -u -d '7 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --metric-data-queries file:///tmp/mdq.json --output json
```

Discovery: `aws cloudwatch list-metrics --namespace AWS/ES ...` (metric names, dimension sets).

**Gotchas:**
- **Node/domain trap:** `ClientId`+`DomainName` = domain aggregate; +`NodeId` = per data
  node. The aggregate is NOT the sum of the node series — never reconstruct one from the other.
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
| `SearchLatency` avg | ~50 ms (post-fix ~26 ms) | > 90 ms |
| `ThreadpoolWriteQueue` | ~0–1 | growing |
| write-reject deltas (all four) | 0 | any |
| `ClusterIndexWritesBlocked` | 0 | 1 = writes rejected outright |
| `FreeStorageSpace` | well above 20 GB | near low-watermark ⇒ ES blocks writes |
| `IndexingLatency` | single-digit ms | — |

Also published (and absent from Grafana): `ShardCount`, `Shards.active`, `2xx/4xx/5xx`,
`JVMGCOldCollectionTime`, `SysMemoryUtilization`, `OpenContexts`, `ThreadpoolSearchThreads`,
`WriteLatency`, `ReadLatency`, `BurstBalance`, `MasterJVMMemoryPressure`.

**2026-08-31 incident baseline** (search-bound; indexing fine throughout): search queue
peaked 872/958, `ThreadpoolSearchRejected` +1,170 domain-wide, CPU 90–99%; all write-reject
counters stayed 0, `FreeStorageSpace` ~19 GB. Node CPU skewed: `-DaP05…` 86–99% vs
`Q8tgjPC3…` 49–77% (shard-0 hotness, see below).

**Correlation rule:** the `sws-api/worker` queries this domain, so ES search saturation
shows up as SQS backlog growth while the worker sits near-idle (I/O-blocked). Worker CPU
≈ 0 + search queue > 700 + rising backlog ⇒ **ES search capacity is the constraint** —
adding worker replicas won't help and adds load.

---

## ES cluster internals — ES API (NO AI ACCESS — user-run only)

**Access:** **Claude has no access to prod Elasticsearch and must never query it** — the
endpoint cannot gate read from write access separately. Instead, and only when directly
relevant to the troubleshooting at hand, write the read-only (GET-only) queries as one
larger copy-pastable batch for the user to run manually (VPN) and paste the output back.
ES *metrics* are still safe to fetch yourself via CloudWatch `AWS/ES` (section above).

Endpoint (for the batches):
`https://search-sws-production-74-kc4urq6grrqkotg37i5kusqogm.eu-central-1.es.amazonaws.com`
(ES 7.9.1 OSS). 4 data nodes + 3 dedicated masters. Main index **shops_v11**:
2 primaries × 1 replica, ~15.1 GB primary / ~30.8 GB total, one shard copy per data node.

**Query** (template for user-run batches):

```bash
ES=https://search-sws-production-74-...  # see above
curl -s "$ES/_cat/indices/shops_v11?v&h=index,health,pri,rep,docs.count,store.size,pri.store.size"
curl -s "$ES/_cat/shards/shops_v11?v&h=shard,prirep,state,store,node"
curl -s "$ES/_cat/nodes?full_id=true&h=id,name,node.role"   # full_id ⇒ id == CloudWatch NodeId
curl -s "$ES/_stats/search?level=shards&pretty"             # per-shard-copy query counters
curl -s "$ES/_cat/thread_pool/search?v&h=node_name,active,queue,rejected"
```

Node map (2026-08-31; re-derive with the two `_cat` commands if AWS replaces a node):

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
  Primary-count changes need a reindex — plan 4 primaries at shops_v12.
- Adaptive replica selection avoids cold/young replicas — a copy can look "dead" in the
  counters; diff `_stats/search?level=shards` over minutes before assuming pinning.
- `search.query_total` values are counters since node/shard start — always diff.
- Disk: ~27 GB usable/node, ~19.5 GB free (2026-08-31) — at the 20 GB comfort line;
  reindex-in-place temporarily doubles used space.
- 2026-08-31 saturation root cause: scraper botnet looping junk `/search` queries; blocked
  in reverse-proxy (`conf.d/block_junk_search.conf`). Post-block baseline: SearchQueue ~0,
  SearchLatency avg ~26 ms, node CPU 12–40%.

---

## Beanstalk web/worker — CloudWatch `AWS/EC2`

**Access:** envs `sws6-production` (web, behind the reverse proxy) and
`sws6-production-worker`. CPU/instances via `CPUUtilization` with the
`AutoScalingGroupName` dimension.

**Query:**

```bash
# find live awseb ASGs (Beanstalk names: awseb-e-<envid>-stack-...)
aws cloudwatch list-metrics --namespace AWS/EC2 --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName \
  --query 'Metrics[].Dimensions[0].Value' --output text | tr '\t' '\n' | sort -u | grep awseb
```

**Gotchas:**
- Web ASG as of 2026-08-31: `awseb-e-m5mpqmrsgz-stack-AWSEBAutoScalingGroup-UkGGt5Rvdn6T`.
  **Immutable deploys/rebuilds rotate the ASG name** (July 2026 was `awseb-e-birfw65gr3-…`) —
  sweep all awseb ASGs by SampleCount to find who carried traffic in a past window.
- **Instance count = CPUUtilization SampleCount / (period/60)** (1-min detailed monitoring
  on). No GroupInServiceInstances — group metrics aren't enabled on awseb ASGs.
- Scale-in trigger: 35% avg CPU lower bound; equilibrium sits just above it — expected
  instances ≈ (avgCPU% × instances) / 35. July 2026 baseline: ~8.3 instances @ ~42.5% CPU
  (6–11 diurnal). Avg CPU far below 35% for hours ⇒ scale-in pinned (raised min, suspended
  process) — check env capacity config.

---

## Logs — CloudWatch Logs Insights

**Access:** `aws logs start-query` / `get-query-results` on the low-priv role
(verified 2026-09-01).

| What | Log group |
|---|---|
| SWS prod app logs (live) | `/starweb/sws/starwebserver.se` (+ `/que-messages`, `/shop-api-v2`, …) |
| ES domain errors/warnings | `/aws/aes/domains/sws-production-74/application-logs` |
| Reverse proxy container logs — **no access logs** (those are S3-only, see below) | `/ecs/reverse-proxy`, `/ecs/reverse-proxy-https` |
| `/aws/elasticbeanstalk/sws6-*` | **dead since ~2026-08-19** — don't use |

**Gotchas:**
- App log messages carry **CEST timestamps in-body**; Insights `@timestamp` is UTC.
- Handy parse: `parse @message /\] \[(?<logger>[^\]]+)\] (?<level>ERROR|CRITICAL): (?<msg>.*)/ | stats count() by logger`

---

## Proxy access logs — S3 only (not in CloudWatch at all)

**Access:** bucket `reverse-proxy-nginx-logs` — the only place access logs exist; the
`/ecs/reverse-proxy*` CloudWatch groups carry container logs, not access logs.
- Raw per-minute (UTC paths): `nginx-logs/reverse-proxy/YYYY/MM/DD/HH/MM/<task-uuid>/log-shipper/access-object<rand>`
  (+ small `error-object*` siblings) — ~73 gzip objects/min **without a .gz extension**.
- Daily compacted: `compacted/reverse-proxy/YYYY/MM/DD/access.log.gz` (~1.3 GB/day).
  **The current day is never compacted yet** — use the raw per-minute prefixes for today.
- `reverse-proxy-athena-results` bucket exists for Athena over these logs.

**Recent window (e.g. last 15 min)** — verified 2026-09-01, ~700 files / ~270k lines, ~15 s
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
2 skipped minutes) plus the ~15 s download. Don't read the empty tail as traffic stopping,
and when correlating with CloudWatch remember its metrics are also ~1 min+ behind (ES/SQS
integration series in Grafana ~5 min).

### Debugging the search endpoint (commands verified 2026-09-01)

Block rules: `conf.d/block_junk_search.conf` (patterns) + `conf.d/invalid_reqest_handler`
(enforcement) in the reverse-proxy repo. Field map for the merged log — split on `"`:
`$2`=request, `$3`=` status bytes `, `$6`=UA; split on whitespace: `$1`=vhost,
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

# heaviest queries by upstream time (rt=)
awk -F'"' '{split($3,a," "); if(a[1]==200 && $2 !~ /get-autocomplete/){match($0,/rt=[0-9.]+/); print substr($0,RSTART+3,RLENGTH-3), $2}}' $D/search.log | sort -rn | head

# burst abuse: IPs with ≥10 autocomplete requests in a single second
awk -F'"' '$2 ~ /get-autocomplete/ {split($1,h," "); print h[2], h[5]}' $D/search.log | sort | uniq -c | awk '$1>=10' | sort -rn
```

Reading the results:
- **Distributed-crawler fingerprint:** ~1–2 reqs/IP across dozens of IPs, implausible
  Chrome-version spread in the UAs, deep `/search?m=…&page=N` pagination. Per-IP rate
  limits are useless against it — pattern or page-cap blocks are the lever.
- **Self-identifying crawlers** (UA token, e.g. `GeedoShopProductFinder`) may sit in a
  single /24 — compare `grep -c '<token>'` with `grep -cE '^[^ ]+ <prefix>\.'`; if equal,
  a CIDR limit is enough.

**Gotchas:**
- `/tmp` is a 1 GB tmpfs — download to `~/.cache/`.
- **Cache cleanup: ask, don't auto-delete.** After each troubleshooting section wraps up —
  or when the disk backing `~/.cache` is approaching full — ask the user whether to clean
  all cache dirs for the current troubleshooting; never delete cached downloads unprompted.
- **Don't stream/grep the download.** For anything bigger than the recent-window recipe
  above (hours, full days), run the `aws s3 cp` to `~/.cache/` as a background task with a
  watcher that fires on completion, and keep troubleshooting other threads in the
  background while it runs; grep the local file once it lands.
- Line format: `vhost client_ip - - [ts +0000] "METHOD /path" status bytes "referer" "UA" rt=… up_ip=… tls=…`
- **Timezone: everything here is UTC** — S3 paths and in-line timestamps (`+0000`) alike.
  But SWS app logs are **CEST in-body** (see Logs section): correlating access log ↔ app
  log naively puts events 2 h apart.

---

## Sentry

**Access:** org `starweb`, project `sws-6`.
**Auth:** Bearer `SENTRY_TOKEN` from `~/.tokens/sentry`.

**Query:**
- Search issues: `GET https://sentry.io/api/0/organizations/starweb/issues/?query=<text>&statsPeriod=14d&sort=freq&limit=10`
- Latest event (tags incl. `shop` + stacktrace): `…/issues/<id>/events/latest/`

**Gotchas:** API can be slow — always `curl --max-time 30`.
