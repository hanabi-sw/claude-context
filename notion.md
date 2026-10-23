# Notion — "where does this doc go?" and workspace lookups — READ-ONLY

Both platforms, SWS machine only (`~/.tokens/notion`; the NEH workstation has no token). Read
when asked where a page belongs in Notion, what the doc standard is, whether something is
already documented, or to read a Notion page. Verified against the live workspace on 2026-10-23.

**Only `GET` / `POST /search` / `POST /databases/*/query`.** Creating, editing, moving or
archiving anything is user-only; hand over the target page link and the proposed title instead.
Rules and failure codes are in `tokens.md` (Notion section).

## Auth and helpers

```sh
set -a; . ~/.tokens/notion; set +a
NH=(-s -H "Authorization: Bearer $NOTION_TOKEN" -H "Notion-Version: 2022-06-28" -H "Content-Type: application/json")
nsearch()   { curl "${NH[@]}" -X POST https://api.notion.com/v1/search -d "{\"query\":\"$1\",\"page_size\":${2:-40}}"; }
nchildren() { curl "${NH[@]}" "https://api.notion.com/v1/blocks/$1/children?page_size=100"; }
npage()     { curl "${NH[@]}" "https://api.notion.com/v1/pages/$1"; }
# one line per result: object, id, parent, title
ntitles() { python3 -I -c '
import json,sys
for r in json.load(sys.stdin)["results"]:
    if r["object"]=="page": t="".join(x["plain_text"] for v in r["properties"].values() if v["type"]=="title" for x in v["title"])
    else: t="".join(x["plain_text"] for x in r.get("title",[]))
    p=r["parent"]; print(r["object"], r["id"], f"parent={p['"'"'type'"'"']}:{p.get(p['"'"'type'"'"'],'"'"''"'"')}", "|", t)'; }
# page body as text: child pages, headings, paragraphs, list items
nbody() { python3 -I -c '
import json,sys
for b in json.load(sys.stdin)["results"]:
    t=b["type"]; v=b[t]
    s=v.get("title") if t in("child_page","child_database") else "".join(x["plain_text"] for x in v.get("rich_text",[])) if isinstance(v,dict) else ""
    if s: print(f"{t:18} {b['"'"'id'"'"'] if t.startswith('"'"'child_'"'"') else '"'"''"'"'} | {s[:200]}")'; }
```

Page URL from an id: `https://www.notion.so/<id without dashes>`. `search` is fuzzy and ranks
recent pages first; it never lists a page the integration is not connected to (`tokens.md`).

```sh
nsearch "mailgun" | ntitles                      # is it documented already? who are the siblings?
nchildren <page-id> | nbody                      # section contents / page text
npage <page-id> | python3 -I -c 'import json,sys;d=json.load(sys.stdin);print(d["parent"])'   # walk up one level
```

## How the workspace is organised

- Top level is by *kind of content*: **Systems and components** (per-system dev/ops docs),
  **Development processes** (how we work), **Technical foundations** (coding standards),
  **Operations** (monitoring/alerting), **Internal Helpdesk** (support-facing merchant issues).
- Platform split happens one level down: `Systems and components → SWS` and `→ NEH`, each
  with `Tasks` (how-tos, imperative titles) and `Reference` (how it works). SWS infra pages
  (AWS, CloudWatch, Beanstalk) live under SWS; NEH hosts, Apache logs, CrowdSec, Mailgun under NEH.
- A customer-facing symptom goes to Internal Helpdesk (→ NEH for NEH shops); anything a
  developer or ops person runs goes to the platform's `Tasks`.

## Workspace map (ids as of 2026-10-23)

| Section | Id | Holds |
|---|---|---|
| **Development processes → Writing good documentation** | `af95f72d-03bd-4ea1-93ac-2be86fd61f6e` | **the doc standard**: Diátaxis (tutorial / how-to / reference / explanation) and "closest to where you'd need it"; its "Cheat sheet" is an image, read it in the browser |
| Systems and components → **SWS** | `c9b8b125-d87e-400c-8bbe-cbfa26cb5fcb` | `Tasks` `1def90fb-3375-8079-b8e6-ca84b0f68e8c` (how-tos: Viewing Logs, Restore a backup for a shop, Connect to Databases…), `Reference` `1def90fb-3375-807d-bb21-e463e48acff8` (Release Management, Operations, Cron Jobs, SWS ENV Variables, APIs…) |
| Systems and components → **NEH** | `1cff90fb-3375-8026-bcb9-c20bd6238601` | `Tasks` `1def90fb-3375-805e-ac38-c3ccaa7dacb2` (Increase NEH disk, View mailgun (Sinch) logs, WAF - Crowdsec, DNS how-tos), `Reference` `1def90fb-3375-80fe-a914-f8d862952f29`, plus flat pages `Log Management` `30df90fb-3375-8024-951e-c6d1d040de8c`, `Servers`, `GIT`, `Release flow` |
| Technical foundations | `1def90fb-3375-80d7-be9e-c27701f7ff6a` | Coding standards (PHP, Frontend), Best practices |
| Development processes | `d33affc6-5b87-4d67-82ac-c8fd39432e46` | Code reviews, Pull Requests, Decision logs, Quality assurance, Special solutions |
| Operations → Monitoring and alerts → NEH | `309f90fb-3375-80ff-b14e-e37b8ef18c92` | alerting only (Overview) |
| Internal Helpdesk → NEH | `153f90fb-3375-8069-9487-ccc939e09abd` | **support-facing** merchant issues and `Buggar`; not for dev/ops how-tos |
| Drafts (workspace root) | `22af90fb-3375-800e-929e-fe60ad515bbc` | unsorted dump of troubleshooting write-ups; never recommend it as a home |

## Answering "where should this go?"

1. Classify the text with Diátaxis. A page that mixes types is split: commands and recipes →
   a how-to under `<platform> → Tasks`; "what is inside / retention / how it works" → the
   existing reference page for that mechanism; "since <date> X changed" → one callout at the top,
   body stays present tense.
2. `nsearch` two or three key words to find the existing page on the same mechanism and its
   siblings; `nchildren` the candidate section to confirm the naming convention (Tasks pages are
   imperative: "Increase NEH disk", "View mailgun (Sinch) logs").
3. Check whether an existing reference page goes stale because of the change and say so.
4. Deliver: target section with link, proposed title in the section's style, what to split
   where, which existing page to update, and the places that do *not* fit and why. The user
   creates and edits the pages.
