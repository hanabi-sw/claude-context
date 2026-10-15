# Token creation & storage

How to (re)create each token used by the troubleshooting and dev-environment guides, and where it lives.
**Minting or revoking a token is a user-only operation — Claude never creates, rotates,
or revokes tokens.** When you realise a token is missing, expired, or under-scoped, guide
the user through the steps below (page, scopes, file, var name) and wait for them to save
the new value. Tokens get the minimum read scopes listed. Never echo a token, paste it
into a URL, or commit it — it lives in its env file, which gets sourced.

## Grafana Cloud (metrics queries)

| | |
|---|---|
| Generate at | <https://starweb.grafana.net/a/grafana-auth-app> (Grafana stack `starweb`) |
| Scopes | read-only metrics query scopes (`metrics:read`) — nothing else |
| Save to | `~/.tokens/grafanacloud` |
| Var name | `GRAFANA_CLOUD_TOKEN` (file is env format: `GRAFANA_CLOUD_TOKEN=<token>`) |
| Paired with | username/instance ID `1181702` — fixed, never changes with the token |

Symptom of an expired/revoked token: queries return `401`. Fix: guide the user to mint a
new token at the page above and update the env-file value; the instance ID never changes.

## Sentry (issue/event queries)

| | |
|---|---|
| Generate at | <https://sentry.io/settings/account/api/auth-tokens/> — **personal auth token** |
| Scopes | `event:read`, `project:read`, `org:read` |
| Save to | `~/.tokens/sentry` |
| Var name | `SENTRY_TOKEN` (file is env format: `SENTRY_TOKEN=<token>`) |
| Used as | `Authorization: Bearer $SENTRY_TOKEN` against org `starweb`, project `sws-6` |

## Docker Hub (private `starweb/*` images for local dev)

| | |
|---|---|
| Generate at | <https://app.docker.com/settings/personal-access-tokens> — **personal access token**, for an account in the `starweb` Docker Hub org |
| Scopes | `Read-only` (Public & private repos) — nothing else |
| Save to | `~/.tokens/dockerhub` |
| Var names | `USERNAME=<docker hub user>` and `TOKEN=<token>` (env format, two lines) |
| Used as | `set -a; . ~/.tokens/dockerhub; set +a; echo "$TOKEN" \| docker login --username "$USERNAME" --password-stdin` |

Needed before `task dev:provision` in `sws-6`: `starweb/sws6-app-dev`, `starweb/sws6-app-base`
and `starweb/oauth-server` are private, every other image in `docker-compose.yml` is public.
Symptom of a missing login: `docker compose up` / `docker manifest inspect` fails with
`pull access denied` or `no such manifest`. The login is cached in `~/.docker/config.json`,
so it is only repeated after a `docker logout` or a token rotation. The same file also holds
an ECR login for `546532984119` that expires after 12 hours — unrelated to Docker Hub.

## Mailgun / Sinch (NEH shop e-mail delivery logs)

| | |
|---|---|
| Generate at | Mailgun dashboard (<https://app.eu.mailgun.com>, log in via Sinch) → account menu → **API Security** → **Mailgun API keys** → *Add new key* |
| Kind / role | account-level **API key** with the **Support** role — enough for logs, domain list and suppression lists (a *domain sending key* cannot read logs or list domains) |
| Save to | `~/.tokens/mailgun` |
| Format | **raw key only**, no `VAR=` prefix (differs from the env-format files above) |
| Used as | `curl --user "api:$(tr -d '[:space:]' < ~/.tokens/mailgun)"` against `https://api.eu.mailgun.net` (EU region, where all NEH shop domains live; the key also works on `https://api.mailgun.net`) |

NEH platform only, SWS does not use Mailgun. Symptom of a bad key: `401 Forbidden`. Symptom
of the wrong region: `404 Domain not found` for a domain that exists. Recipes are in
`troubleshooting/mailgun-shop-mail.md`.

## AWS (CloudWatch / S3 / SQS reads)

Not a mintable token — the default profile is preconfigured via `credential_process` to
assume `SebastianLockwoodLowPriv`. Nothing to create or rotate here; verify with
`aws sts get-caller-identity`. Setup of the credential helper is out of scope for this file.

## Favro (ticket and board lookups)

| | |
|---|---|
| Generate at | Favro → click the organization name top left → **Settings** → **My account** → **API tokens** → set **Read only** → *Create* (<https://favro.com/organization/d98323ed4cfac48a92f11bf7/5d907e7ad6010016b8547901?onShow=userprofile>) |
| Scopes | **Read only** — we never write to Favro from Claude; a read-only token makes every `POST`/`PUT`/`DELETE` fail |
| Save to | `~/.tokens/favro` |
| Var name | `FAVRO_TOKEN` (file is env format: `FAVRO_TOKEN=<token>`) |
| Used as | HTTP basic, user = the **Favro login e-mail** of the token owner (`sebastian.lockwood@starweb.se`, not the `sl@` alias), password = `$FAVRO_TOKEN`, plus header `organizationId: d98323ed4cfac48a92f11bf7` (Thea Commerce) |

Symptom of a bad e-mail or token: `401 Something went wrong. Please check your credentials.`
A `403 Access denied` on a card lookup means the card does not exist, not a token problem.
Recipes are in `troubleshooting/favro-tickets.md`.
