# Tokens — where each one lives and how to (re)create it

Both platforms. Read when a recipe needs an API token, a call returns `401`/`403`, or a token is
missing, expired or under-scoped. **Minting, rotating or revoking a token is user-only: Claude never
creates one.** Guide the user through the page, scopes, file and var name below and wait for them
to save it. Tokens get the minimum read scopes listed. Never echo a token, paste it into a URL,
a doc, a chat reply or a commit — it lives in its file, which gets sourced or read into a variable.

## Which machine am I on?

```sh
ls ~/.tokens; command -v aws && aws sts get-caller-identity
```

| Machine | `~/.tokens/` | AWS | Notes |
|---|---|---|---|
| NEH workstation | `favro`, `gh-ro`, `mailgun` | none | has `/home/user/code/neh*`; the SWS rows below cannot be used here — say so |
| SWS machine | `favro`, `gh-ro`, `grafanacloud`, `sentry`, `dockerhub`, `notion` (no `mailgun`) | default profile → `SebastianLockwoodLowPriv` | has `~/code/sws-6` |

Two file formats are in use: **env format** (`VAR=<token>`, load with `set -a; . ~/.tokens/x; set +a`)
and **raw** (the bare key, load with `$(tr -d '[:space:]' < ~/.tokens/x)`). Check which one a file
has without printing it: `awk -F= 'NF>1{print $1"="} NF<=1{print "(raw)"}' ~/.tokens/x`.

## Both platforms

### Favro (ticket and board lookups)

| | |
|---|---|
| Generate at | Favro → organization name top left → **Settings** → **My account** → **API tokens** → set **Read only** → *Create* (<https://favro.com/organization/d98323ed4cfac48a92f11bf7/5d907e7ad6010016b8547901?onShow=userprofile>) |
| Scopes | **Read only** — a read-only token makes every `POST`/`PUT`/`DELETE` fail |
| Save to | `~/.tokens/favro`, env format `FAVRO_TOKEN=<token>` |
| Used as | HTTP basic, user = the **Favro login e-mail** of the token owner (`sebastian.lockwood@starweb.se`, not the `sl@` alias), password = `$FAVRO_TOKEN`, header `organizationId: d98323ed4cfac48a92f11bf7` (Thea Commerce) |

`401 Something went wrong. Please check your credentials.` = bad e-mail or token.
`403 Access denied` on a card lookup = the card does not exist, not a token problem. Recipes: `favro.md`.

### GitHub (`gh`, read-only)

| | |
|---|---|
| Generate at | <https://github.com/settings/tokens> — personal access token for the `starweb` org, **read-only** |
| Save to | `~/.tokens/gh-ro`, **raw** token (no `VAR=` prefix) |
| Used as | `GH_TOKEN=$(tr -d '[:space:]' < ~/.tokens/gh-ro) gh …` |

Can read PRs, issues and branches; `gh pr create` and `gh pr comment` fail with
`Resource not accessible by personal access token` — the user opens and describes PRs (hand over
`https://github.com/starweb/<repo>/pull/new/<branch>` plus the body). **Never delete a remote
branch**: it auto-closes the branch's PR and this token cannot reopen it. Push new branches with `-u`.

## NEH platform

### Mailgun / Sinch (shop e-mail delivery logs)

| | |
|---|---|
| Generate at | Mailgun dashboard (<https://app.eu.mailgun.com>, log in via Sinch) → account menu → **API Security** → **Mailgun API keys** → *Add new key* |
| Kind / role | account-level **API key** with the **Support** role — enough for logs, domain list and suppression lists (a *domain sending key* cannot read logs or list domains) |
| Save to | `~/.tokens/mailgun`, **raw** key only |
| Used as | `curl --user "api:$(tr -d '[:space:]' < ~/.tokens/mailgun)"` against `https://api.eu.mailgun.net` (EU region, where all NEH shop domains live) |

Workstation convention only: on the hosts, `/usr/local/bin/mailgunSyncDomains.sh` reads
`MAILGUN_KEY` (plus `MYSQL_PASS`, `NEH_DKIM_PEM`) from its environment, sourced from Bitwarden.
Symptom of a bad key: `401 Forbidden`. Wrong region: `404 Domain not found` for a domain that
exists. Recipes: `neh/mailgun.md`. SWS does not use Mailgun.

## SWS platform (SWS machine only)

Verified on the SWS machine on 2026-10-23: all four files exist in the stated format, Grafana,
Sentry and Notion answer, Docker Hub is logged in, `aws sts get-caller-identity` returns the
low-priv role. Mint-page URLs are not re-checked (browser only).

### Grafana Cloud (metrics queries)

| | |
|---|---|
| Generate at | <https://starweb.grafana.net/a/grafana-auth-app> (Grafana stack `starweb`) |
| Scopes | read-only metrics query scopes (`metrics:read`) — nothing else |
| Save to | `~/.tokens/grafanacloud`, env format `GRAFANA_CLOUD_TOKEN=<token>` |
| Paired with | username/instance ID `1181702` — fixed, never changes with the token |

Expired/revoked token: queries return `401`; the instance ID never changes.

### Sentry (issue/event queries)

| | |
|---|---|
| Generate at | <https://sentry.io/settings/account/api/auth-tokens/> — **personal auth token** |
| Scopes | `event:read`, `project:read`, `org:read` |
| Save to | `~/.tokens/sentry`, env format `SENTRY_TOKEN=<token>` |
| Used as | `Authorization: Bearer $SENTRY_TOKEN` against org `starweb`, project `sws-6` |

`{"detail":"Invalid token"}` = expired.

### Docker Hub (private `starweb/*` images for local dev)

| | |
|---|---|
| Generate at | <https://app.docker.com/settings/personal-access-tokens> — **personal access token**, for an account in the `starweb` Docker Hub org |
| Scopes | `Read-only` (Public & private repos) — nothing else |
| Save to | `~/.tokens/dockerhub`, env format, two lines: `USERNAME=<docker hub user>` and `TOKEN=<token>` |
| Used as | `set -a; . ~/.tokens/dockerhub; set +a; echo "$TOKEN" \| docker login --username "$USERNAME" --password-stdin` |

Needed before `task dev:provision` in `sws-6`: `docker-compose.yml` pulls `starweb/sws6-app-dev`,
`starweb/sws-mysql`, `starweb/sws-elasticmq` and `starweb/oauth-server` from the org; the rest is public. Missing
login: `pull access denied` / `no such manifest`. The login is cached in `~/.docker/config.json`
and only repeated after `docker logout` or a rotation; that file also holds an ECR login for
`546532984119` that expires after 12 hours — unrelated to Docker Hub.

### Notion (workspace page/database reads)

| | |
|---|---|
| Generate at | <https://app.notion.com/developers/tokens?spaceId=925978f4-601b-4534-aba1-c7f551a2ae57> — **internal integration** in the `Starweb` workspace; the current one is `thea-sw-dev-nova1` |
| Capabilities | Content: **Read content** only; Comments: none; User info: **No user information** |
| Save to | `~/.tokens/notion`, env format `NOTION_TOKEN=<token>` (starts with `ntn_`) |
| Used as | `Authorization: Bearer $NOTION_TOKEN` plus `Notion-Version: 2022-06-28` against `https://api.notion.com/v1/` |

**Read-only. No write of any kind to Notion** — creating, editing, moving, archiving or deleting
pages, databases, properties or comments, through this token, the Notion MCP connector or any other
route — without the user's explicit consent for that specific change. The token's read-only
capabilities are a backstop, not the rule: ask first, every time.

An integration only sees pages it has been connected to: page **⋯ → Connections → add
`thea-sw-dev-nova1`** (child pages inherit). Bad or revoked token: `401` `{"code":"unauthorized"}`.
Page not connected: `404 object_not_found` or empty `search` results — fix the connection, not the
token. Verify with `GET /v1/users/me` (returns the bot name and `workspace_name`).

### AWS (CloudWatch / S3 / SQS / RDS reads)

Not a mintable token — the default profile is preconfigured via `credential_process` to assume
`SebastianLockwoodLowPriv`. Nothing to create or rotate; verify with `aws sts get-caller-identity`.
Never use the `prod-admin` / `prod-pulumi` profiles for reads; ask before using them at all.
Setup of the credential helper is out of scope for this file.
