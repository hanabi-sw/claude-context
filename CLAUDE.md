# claude-context — shared Claude knowledge base

Durable context for Claude sessions, split by topic. Read only what the task needs.

## troubleshooting/prod-observability.md

**Read this whenever troubleshooting or investigating anything in SWS production or
staging**, specifically before:

- Querying prod metrics or logs from any source — Grafana Cloud, CloudWatch
  (metrics or Logs Insights), S3 access logs, or Sentry. It holds the endpoints,
  auth, read-only rules, and per-source query boilerplate.
- Diagnosing Elasticsearch/OpenSearch health, search saturation, or indexing issues
  (includes the **no-direct-ES-access rule**: hand query batches to the user).
- Investigating SQS backlog, DLQ contents, or the `sws-api/worker` consumer.
- Analyzing reverse-proxy traffic: bot/scraper activity, junk-search blocks,
  search-endpoint debugging (verified command recipes included).
- Checking Beanstalk web/worker scaling or instance counts.
- Correlating any of the above across sources (timezone and metric-lag traps included).

Do **not** load it for pure code work in the SWS/reverse-proxy repos that touches no
production system.

## token-creation.md

**Read when a token is missing, expired (`401`), or needs rotating** — Grafana Cloud or
Sentry. Covers the generation page, required read scopes, env-file path and var name for
each. Minting is **user-only**: never create a token — guide the user through it.
