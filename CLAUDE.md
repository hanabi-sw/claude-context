# claude-context — shared Claude knowledge base

Durable context for Claude sessions, split by topic. Read only what the task needs.

## Git conventions

- Commit only when the user asks; never push without an explicit go-ahead.
- One-line Conventional Commits (`docs: …`, `fix: …`, `chore: …`), ≤ 72 chars, imperative
  mood. **No body, no trailers** (no `Co-Authored-By`, no `Generated with`).
- One logical change per commit: a new guide, an index update and an unrelated path fix are
  separate commits.
- Docs are written in the present tense — how things work now, not what was done.

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

## troubleshooting/worker-queue-cron.md

**Read this when the Beanstalk worker or its queue misbehaves**, specifically when:

- https://starwebserver.se/app/status/cron warns `Last cron job ran … minutes ago`.
- `sws6-production-worker` is Yellow/Red, or the `sws6-production` SQS backlog grows.
- Queued jobs are late: order emails, ES indexing, Fortnox/Hogia/Ongoing syncs, sales reports.
- One Aurora writer (`sws-6-1`/`sws-6-2`) is pinned and you need Performance Insights to
  name the job and shop behind it.

It holds the diagnosis order, Logs Insights / PI / SQS / S3 recipes, the command gotchas,
what not to do, and the 2026-10-07 reference incident. Still read
`prod-observability.md` first for auth and the read-only rules.

## token-creation.md

**Read when a token is missing, expired (`401`), or needs rotating** — Grafana Cloud or
Sentry. Covers the generation page, required read scopes, env-file path and var name for
each. Minting is **user-only**: never create a token — guide the user through it.
