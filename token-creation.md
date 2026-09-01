# Token creation & storage

How to (re)create each token used by the troubleshooting guides, and where it lives.
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
| Save to | `~/.grafana-cloud/token.env` |
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

## AWS (CloudWatch / S3 / SQS reads)

Not a mintable token — the default profile is preconfigured via `credential_process` to
assume `SebastianLockwoodLowPriv`. Nothing to create or rotate here; verify with
`aws sts get-caller-identity`. Setup of the credential helper is out of scope for this file.
