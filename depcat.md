# depcat — dependency inventory and vulnerability queries

Both platforms. Read when the task asks what is installed where, which hosts need a reboot, which hosts stopped
reporting, or what is vulnerable, from the depcat server instead of ssh-ing around.
Verified against depcat@86a4234 on 2026-11-05.

depcat (`starweb/depcat`, clone `/home/user/code/depcat`) collects a daily report per host (NEH hosts via the
`depcat` role in `neh-infrastructure`; `lucio` by hand) and per CI build, and the server matches every package
against OSV/EPSS/KEV. This page is the short version for this workstation.

**Canonical docs live in the depcat repo**, `main` branch: <https://github.com/starweb/depcat/tree/main/docs>.
When this page and they disagree, they win. Most used:

- query recipes: <https://github.com/starweb/depcat/blob/main/docs/how-to/query-the-inventory.md>
- read API routes and fields: <https://github.com/starweb/depcat/blob/main/docs/reference/server-api.md>
- tokens: <https://github.com/starweb/depcat/blob/main/docs/how-to/issue-a-client-token.md>
- local audit: <https://github.com/starweb/depcat/blob/main/docs/how-to/audit-a-host-locally.md>
- trace a vulnerability: <https://github.com/starweb/depcat/blob/main/docs/how-to/trace-a-vulnerability.md>

## Observability: querying depcat

**Only the dev cluster is live** (k8s-dev). There is no prod depcat server yet (it comes with its own release PR),
so everything below queries dev. `environment=prod` in a query filters on the subject's environment (lucio
reports as `prod`), not on which server answers.

| Listener | URL | Answers |
|---|---|---|
| internal read API (tailnet) | `https://depcat.k8s-dev.sw-test.se` | every `GET /v1/…` read route, with a `read` token |
| public ingest (dev) | `https://depcat.k8s-dev.external.sw-test.se` | only `POST /v1/reports` and `GET /healthz`; everything else 404 by design |

Reads need a `read` token in `~/.tokens/depcat` (see `tokens.md` §depcat). An ingest token on a read route gets
`403`. Read-only by nature: nothing below changes the server.

```sh
set -a; . ~/.tokens/depcat; set +a          # DEPCAT_READ_TOKEN
DEPCAT=https://depcat.k8s-dev.sw-test.se
q() { curl -sf -H "Authorization: Bearer $DEPCAT_READ_TOKEN" "$DEPCAT$1"; }
```

| Question | Query |
|---|---|
| What is vulnerable, most urgent first? | `q '/v1/vulns?system=neh&min_priority=P2' \| jq -r '.vulns[] \| "\(.priority_name)\t\(.id)\t\(.name) \(.version) -> \(.fixed_version // "no fix")\t\([.subjects[].id] \| join(","))"'` |
| Known-exploited (KEV) count | `q '/v1/vulns?kev=true' \| jq '.count'` |
| Which hosts need a reboot? | `q '/v1/hosts?system=neh&reboot_pending=true' \| jq -r '.hosts[] \| "\(.id)\t\(.kernel_running) -> \(.kernel_newest_installed)"'` |
| Which hosts stopped reporting? | `q '/v1/hosts?stale=24h' \| jq -r '.hosts[] \| "\(.system)/\(.id)\t\(.latest_collected_at // "never")"'` |
| Did a collector fail? | `q '/v1/hosts' \| jq -r '.hosts[] \| select(.coverage \| to_entries \| any(.value != "ok")) \| "\(.id)\t\(.coverage)"'` |
| Who runs package X? | `q '/v1/packages?name=openssl&type=deb' \| jq -r '.packages[] \| "\(.system)/\(.subject)\t\(.version)"'` (`*` suffix = prefix match) |
| Everything on one host | `q '/v1/hosts/nehdev-cust-tx?system=neh' \| jq '{os: .host.os.pretty_name, packages: (.packages \| length)}'` |

Subjects reporting today: `neh/host/nehdev-cust-tx` (role, once deployed) and `local/host/lucio` (by hand,
Debian 10). `system` is part of every subject: query lucio with `system=local`, not `neh`.

### Before trusting an empty answer

- `/v1/vulns` also returns `identities` (how many are `pending`, `error`, `unsupported_type`) and
  `coverage_gaps` (hosts whose latest report had a failed collector). Read both before saying "clean".
- **End-of-life OS looks clean.** Debian stops recording fixes for a release after its EOL, so packages on
  Debian 10 (`lucio`) with post-EOL vulnerabilities match nothing. Only pre-EOL fixes (old kernels) show up.
- Standalone binaries (exporters) have no advisory feed: counted as not checkable.

### Without a token

On a host that runs the collector, the local report can be audited straight against the public feeds, no server
and no token (verified on lucio 2026-11-05):

```sh
/usr/local/bin/depcat audit --from /var/lib/depcat/latest.json --min-priority P2
```

Exit code `4` means findings at or above the threshold. NEH hosts are reached through
`neh-monitoring`'s tooling, never ssh (see `/home/user/code/neh-monitoring/CLAUDE.md`).
