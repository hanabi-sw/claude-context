# Handover — for the agent on the SWS/SCS/AWS machine

Temporary file. Delete it (and the "Unverified" banners) in the commit that finishes this work.

## What happened on the NEH workstation (2026-10-23)

The KB was restructured so that `CLAUDE.md` is a ≤ 60-line lookup table imported by
`~/.claude/CLAUDE.md` on every machine, with all detail behind links (`README.md` has the layout,
the size rule and the doc conventions). Files were regrouped by platform:

| Old | New |
|---|---|
| `token-creation.md` | `tokens.md` (+ GitHub `gh-ro` row, machine probe, platform headings) |
| `troubleshooting/favro-tickets.md` | `favro.md` |
| `neh-php-entrypoints.md`, `neh-auth-model.md`, `troubleshooting/mailgun-shop-mail.md` | `neh/php-entrypoints.md`, `neh/auth-model.md`, `neh/mailgun.md` — **re-verified against the repos and corrected** |
| `troubleshooting/prod-observability.md`, `troubleshooting/worker-queue-cron.md`, `dev-env/sws-6-local.md` | `sws/prod-observability.md`, `sws/worker-queue-cron.md`, `sws/local-dev.md` — **links fixed only, content untouched** |

On that machine `~/.claude/CLAUDE.md` is now just `@/home/user/code/claude-context/CLAUDE.md`
plus one sentence. Do the same on this machine (user-scope imports need no approval dialog).

## Your part: verify and refresh the SWS docs

Nothing below could be checked from the NEH workstation (no AWS profile, no Grafana/Sentry/Docker
Hub/Notion tokens, no `sws-6` checkout). For each doc: check every concrete claim, fix what is
wrong, add a `Verified against <source> on <date>` line under the scope sentence, remove the
banner. One commit per doc, one-line conventional message, no trailers, no push without go-ahead.

### `sws/prod-observability.md` (last verified 2026-09-01 per its own text)
- Grafana Cloud endpoint, instance ID `1181702`, `up` empty, `~747` metric names.
- Is Grafana's `aws_sqs_*` scrape still dead? Still "always query CloudWatch"?
- Worker deployment facts (1 replica, no HPA, requests/limits) in `sws-api-production2`.
- ES: domain names, node IDs and the shard-0/shard-1 node map (re-derive with the two `_cat`
  commands via the user — Claude never queries ES), `shops_v11` still current or `v12` done?
  Disk free vs the 20 GB line. Thresholds still sensible post-fix.
- Beanstalk web ASG name (rotates on immutable deploys) and the instance-count formula.
- Log groups: `/aws/elasticbeanstalk/sws6-*` still dead? `/starweb/sws/starwebserver.se` streams.
- S3 bucket layout for proxy logs, compaction lag, the 15-minute recipe (run it once).
- The `block_junk_search.conf` / `invalid_reqest_handler` file names in the reverse-proxy repo.
- Sentry org/project; `--max-time 30` still needed.
- Consider moving the 2026-08-31 incident narrative into a short "Reference incident" tail.

### `sws/worker-queue-cron.md` (last verified 2026-10-07)
- Worker env/ASG name, sqsd settings (`HttpConnections`, timeouts, `MaxRetries`), queue URL.
- Aurora instance names and classes; PI still works on the low-priv role; `db.sql` group only.
- Status page logic (`StatusController::cronAction`, 20-min threshold) in current `sws-6`.
- CloudWatch stream names and which groups are dead.
- Report-job S3 path (`starweb-static-production/data/shops/<code>/reports/<hash>/`).
- The "code fixes to propose" list: has any landed? If so, update or drop.

### `sws/local-dev.md` (undated)
- `task` targets exist in the `sws-6` Taskfile (`dev:provision`, `dev:status`, `test:*`,
  `wt:provision`); the `--clean-npm` flag; ports list; `mise` install path for `task`.
- The three private images and the `starweb` external network.
- Add a "Verified against sws-6@<sha>" line.

### `tokens.md`, SWS section
- Each of `grafanacloud`, `sentry`, `dockerhub`, `notion` exists in `~/.tokens/` with the stated
  format (check with the `awk` one-liner in the file; never print values).
- `aws sts get-caller-identity` returns `SebastianLockwoodLowPriv`.
- Mint pages still correct (Grafana auth app URL, Notion integration name).

### `CLAUDE.md` (the index)
- Add nothing unless a doc is missing a row. Keep it ≤ 60 lines (`wc -l`). Trigger phrases in the
  SWS rows were written from the old prose index; tighten them if they miss how tasks are phrased
  on that side.

## Style targets for the whole KB (apply where you touch)
- One-sentence scope + "Verified against" line under the title; present tense; verified commands
  only; `file:line` pointers over quoted code; repo names as cloned (`sws-6`, never `ansible`).
- Keep each doc under ~250 lines; move incident narratives to a dated tail.
- Read-only everywhere; any write is handed to the user as a command.

## When done
Remove the three banners and this file, commit (`docs: verify SWS docs on the SWS machine` or
per-doc), get the go-ahead to push, and tell the user to `git pull` on the NEH workstation.
