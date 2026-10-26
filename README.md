# claude-context — how this knowledge base works

Durable context for Claude sessions, shared through this git repo between the NEH workstation and
the SWS/SCS/AWS machine. `CLAUDE.md` is the only file that is always in context (imported by
`~/.claude/CLAUDE.md` on each machine); everything else is read on demand when a row of its lookup
table matches the task. Keep `CLAUDE.md` under 60 lines: one row per doc, trigger phrases first,
no explanations — those belong in the doc.

## Layout

```
CLAUDE.md              always-loaded lookup table (≤ 60 lines)
README.md              this file
tokens.md              every token: file, format, auth recipe, scopes, mint page, failure symptoms
favro.md               Favro tickets and the Day-to-day board (both platforms)
notion.md              Notion workspace map, read-only lookups, where a new page belongs (SWS machine)
neh/                   Nordisk eHandel platform (Perl shop framework, GCP hosts, neh* repos)
  php-entrypoints.md   where PHP runs, kill-switch, /admin allowlist, phpMyAdmin
  auth-model.md        who can reach which URL, Apache merge-order traps, token login
  mailgun.md           shop mail delivery via Mailgun (postfix → Mailgun → recipient)
sws/                   Starweb SWS platform (sws-6 on AWS: Beanstalk, Aurora, ES, SQS, reverse proxy)
  prod-observability.md  read-only access and recipes for every prod signal source
  worker-queue-cron.md   Beanstalk worker / SQS / cron diagnosis
  local-dev.md           sws-6 Docker dev env and test suites
  s3-media-restore.md    static-assets bucket: versions, delete markers, restoring deleted media files
HANDOVER-*.md          temporary: work handed to the agent on the other machine; deleted when done
```

Group by platform: the first question every doc used to answer in its preamble was "NEH or SWS?".
The directory answers it, so a doc's scope line is one sentence.

## Adding to the index (`CLAUDE.md`) — keep it a lookup table

`CLAUDE.md` is loaded into every session on every machine, so each line costs context everywhere,
forever. Rules, enforced on every edit:

- **Hard cap 60 lines.** If a new row does not fit, merge or shorten rows; never exceed it.
- **One row per doc, in the table.** A row is `| <path> | when the task… |` with trigger phrases a
  reader can match against their task. No prose sections, no recipes, no history, no "why".
- **Explanations go in the doc, not the index.** If a fact needs more than the trigger phrase, it
  belongs behind the link.
- **The rules block stays ≤ 10 lines** and only holds rules that apply to *every* session (token
  handling, read-only, machine detection). Anything platform- or task-specific is a row.
- **No duplication of sibling files.** `neh-monitoring/CLAUDE.md`, `neh-infrastructure/CLAUDE.md`
  and the repos' readmes are pointed at, never summarised.
- Check with `wc -l CLAUDE.md` before committing an index change.

## Writing a doc

- Start with the title, a one-sentence scope ("NEH only. Read when …"), and a line
  `Verified against <repo>@<short sha> on <YYYY-MM-DD>` so the next reader knows how stale it is.
- Present tense: how things work now, not what was done. Incidents go in a short
  "Reference incident" tail with their date, not in the body.
- Verified commands only; mark anything unverified. Prefer `file:line` pointers over quoting code.
- Repo names as they are cloned here: `neh`, `neh-plugins`, `neh-infrastructure`, `neh-monitoring`,
  `sws-6` — never `ansible`.
- Links are repo-relative (`neh/mailgun.md`, `../tokens.md`); absolute paths only for files outside
  this repo.
- A doc that cannot be verified on the machine you are on gets a banner at the top:
  `> **Unverified on <machine> since <date>** — see HANDOVER-<x>.md`. Remove it when verified.
- Read-only is the default for every external system. If a recipe needs a write, give the user the
  command to run instead of running it.

## Git conventions

- Commit only when the user asks; never push without an explicit go-ahead.
- One-line Conventional Commits (`docs: …`, `fix: …`, `chore: …`), ≤ 72 chars, imperative mood.
  **No body, no trailers** (no `Co-Authored-By`, no `Generated with`).
- One logical change per commit: a new guide, an index update and an unrelated path fix are
  separate commits.
- Never commit a token, a password, or a file from `~/.tokens/`.

## Machines

| Machine | Has | Does not have |
|---|---|---|
| NEH workstation | `~/.tokens/{favro,gh-ro,mailgun}`, `/home/user/code/neh*`, VPN to NEH hosts | AWS, Grafana Cloud, Sentry, Docker Hub, Notion, `sws-6` |
| SWS machine | `~/.tokens/{favro,gh-ro,grafanacloud,sentry,dockerhub,notion}`, AWS low-priv profile, `~/code/sws-6` | NEH host access, `mailgun` |

`ls ~/.tokens` tells you which one you are on. Do not try the other machine's systems.
