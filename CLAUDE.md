# claude-context — lookup table

Always loaded (imported by `~/.claude/CLAUDE.md`). Open a doc only when its row matches the task.
**Editing this file: add a row, never a paragraph. Hard cap 60 lines; details go in the linked doc (`README.md`).**

## Rules that apply everywhere

- Every external system is **read-only** from Claude; anything that writes is handed to the user as a command.
- Tokens live in `~/.tokens/<service>`, one file each. Never echo one, put it in a URL, a doc or a commit.
  Minting, rotating or revoking a token is **user-only**; `tokens.md` has the page and scopes per service.
- Which machine is this? `ls ~/.tokens` (and `aws sts get-caller-identity` if `aws` exists):
  **NEH workstation** = `favro gh-ro mailgun` only, no AWS, has the `neh*` repos;
  **SWS machine** = `favro gh-ro grafanacloud sentry dockerhub notion` (no `mailgun`) + the AWS low-priv profile, has `~/code/sws-6`.
  Do not attempt the other machine's systems; say they are unavailable here.
- Repo clones here: `/home/user/code/{neh,neh-plugins,neh-infrastructure,neh-monitoring}` — their own `CLAUDE.md`/readme
  come first for code work. Editing this knowledge base: `README.md`.

## When the task… → open

| Open | when the task… |
|---|---|
| `tokens.md` | needs any API token or credential, gets `401`/`403`, or a token is missing/expired/under-scoped |
| `favro.md` | mentions `THE-<n>` / a Favro card, a PR or branch named after one, or asks what is in progress / up next on the Day-to-day board |
| `/home/user/code/neh-monitoring/CLAUDE.md` | investigates an **NEH host or shop**: slow or locked shop, `MysqlDown`/`ApacheNoSlots`, "what ate the box at 03:14", customer sees 429s/bans; needs an access log, atop history, journal or live `ps` (`neh-asset-downloader.sh`, never ssh); adds a silence or queries Prometheus/Grafana |
| `/home/user/code/neh-infrastructure/CLAUDE.md` | asks what is deployed on an NEH host (`/etc/ansible_runs`), which role/tag does what, or touches Ansible; its `roles/crowdsec/CLAUDE.md` is the rate-limit/ban runbook; the nightly SE log archive / awstats pipeline (`makestats.sh`, `/home/archive/log/*.tar.zst`) is owned by `roles/neh-install` (tag `awstats`), not by `neh` |
| `neh/php-entrypoints.md` | changes or reasons about **PHP on an NEH host**: kill-switch, `/admin/` allowlist, phpMyAdmin, ezFilemanager, mod_php packages |
| `neh/auth-model.md` | asks who can reach an NEH URL: authenticated Locations, unauthenticated callbacks, multiserver token login, why `<Files>`/`<Directory>` rules may not hold on `/admin` |
| `neh/mailgun.md` | an **NEH shop e-mail did not arrive** and postfix on the host already shows `status=sent` to `smtp.eu.mailgun.org` (SWS does not use Mailgun) |
| `sws/prod-observability.md` | troubleshoots **SWS production/staging**: CloudWatch metrics/Logs Insights, proxy access logs in S3, Sentry, Elasticsearch health/`/search` slowness, Beanstalk web scaling, bot/scraper traffic, "who is hammering shop X", Grafana Cloud (not for NEH, not for pure code work) |
| `sws/worker-queue-cron.md` | `starwebserver.se/app/status/cron` warns, `sws6-production-worker` is Yellow/Red, the SQS backlog or DLQ grows, queued jobs (order mails, ES indexing, Fortnox/Hogia/Ongoing, sales reports / `generateReport`) are late or slow, or an Aurora writer is pinned |
| `sws/local-dev.md` | sets up or repairs the `sws-6` local Docker dev env or runs its PHPUnit suites |

Not here: shop behaviour, order handling, templates, release process → `/home/user/code/neh/readme.md`; per-customer code → `neh-plugins` (check the branch first).
