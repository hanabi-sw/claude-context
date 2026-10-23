# Favro — tickets and the Day-to-day board — READ-ONLY

Favro is our **primary ticketing system** (organization *Thea Commerce*, prefix `THE`).
Every dev task, bug and incident is a card like `THE-24684`, and GitHub branches and PRs
carry that ID (`THE-24580-price-history-...`, `fix/THE-24232-...`), so
`grep -i THE-24684` over `git log` / `git branch -r` finds the PRs for a card. Read this
when a task mentions a Favro ID, when you need the context behind a PR, or when asked
what is in progress / up next.

**Only `GET`.** The token is read-only; never attempt `POST`/`PUT`/`DELETE` (creating or
moving cards, commenting, changing fields). If a write is needed, give the user the card
link and let them do it in the UI.

## Auth

| | |
|---|---|
| Token | `~/.tokens/favro`, env format `FAVRO_TOKEN=<token>`; creation in `tokens.md` |
| Basic-auth user | the token owner's **Favro login e-mail** `sebastian.lockwood@starweb.se` (`sl@starweb.se` gives `401`) |
| Header | `organizationId: d98323ed4cfac48a92f11bf7` on every call except `/organizations` |

```sh
set -a; . ~/.tokens/favro; set +a
fav() { curl -s -u "sebastian.lockwood@starweb.se:$FAVRO_TOKEN" \
          -H "organizationId: d98323ed4cfac48a92f11bf7" "https://favro.com/api/v1/$1"; }
```

`401 … check your credentials` = wrong e-mail or token. `403 Access denied` on a card
lookup = **the card does not exist** (not 404). Rate limit is 10 000/window, see
`x-ratelimit-remaining`. All timestamps are UTC.

## Grab a ticket by ID

```sh
fav "cards?cardSequentialId=THE-24684&unique=true&descriptionFormat=markdown" | python3 -I -c '
import json,sys
for c in json.load(sys.stdin)["entities"]:
    print("THE-%s | %s" % (c["sequentialId"], c["name"]))
    print("column", c.get("columnId"), "| assigned", [a["userId"] for a in c["assignments"]], "| tags", c["tags"])
    print("links", [f["link"] for f in c["customFields"] if "link" in f]); print()
    print(c.get("detailedDescription") or "(no description)")'
```

- `cardSequentialId` reads only the digits: `24684`, `THE-24684`, `the-24684` are the same
  card, and a typo in the prefix is never caught.
- **Always `unique=true`**: without it the card comes back once per board instance, and the
  copy with `widgetCommonId: null` sits on no board and has no column.
- `descriptionFormat=markdown` makes `detailedDescription` readable (default is HTML).
- Comments: `fav "comments?cardCommonId=<cardCommonId>"`. `cardCommonId` is the stable
  card ID, `cardId` one board instance.
- Link for the user: `https://favro.com/organization/d98323ed4cfac48a92f11bf7/5d907e7ad6010016b8547901?card=THE-24684`

## The Day-to-day board

Collection *Dev - Day-to-day* `5d907e7ad6010016b8547901` holds three boards: **Day-to-day**
`1f82892dac368f922fe9aa2b` (the working board), *Auto-PRs* `86b9898f5a0b697bddd41698`
(cards auto-created from GitHub PRs) and *Stories* `ad739bbfdd42bf5d93d88931`.

Day-to-day columns: Up next `01fd0a82c19b49616d5e949d` · In progress
`0ce541b23968eb9b31f2d8a6` · Ready for review `efedbe5dc66bf95748721784` · In review
`864c090035b257858140396d` · Review approved `ac4f687b17f180fa41153c92` · Ready for release
`8e48b2aa9389332aa0f56e19` · Done `0bf405cf6fa491236b9f0053`.

```sh
# what is In progress right now (swap columnId for another column; drop it for the whole board)
fav "cards?widgetCommonId=1f82892dac368f922fe9aa2b&columnId=0ce541b23968eb9b31f2d8a6&unique=true" \
  | python3 -I -c '
import json,sys
for c in json.load(sys.stdin)["entities"]:
    print("THE-%s | %s | %s" % (c["sequentialId"], c["name"], [a["userId"] for a in c["assignments"]]))'
```

```sh
# whole board incl. Done (~1 700 cards, 100 per page): loop pages, reuse requestId, skip lanes
W=1f82892dac368f922fe9aa2b
first=$(fav "cards?widgetCommonId=$W&unique=true")
read pages rid < <(printf '%s' "$first" | python3 -I -c 'import json,sys;d=json.load(sys.stdin);print(d["pages"],d["requestId"])')
for p in $(seq 0 $((pages-1))); do fav "cards?widgetCommonId=$W&unique=true&page=$p&requestId=$rid"; done \
  | python3 -I -c '
import json,sys
cols={c["columnId"]:c["name"] for c in json.loads(sys.argv[1])["entities"]}
dec=json.JSONDecoder(); buf=sys.stdin.read(); i=0
while i<len(buf):
    i=len(buf)-len(buf[i:].lstrip())
    if i>=len(buf): break
    d,i=dec.raw_decode(buf,i)
    for c in d["entities"]:
        if c.get("isLane"): continue   # lane rows (Priority, NEH, SWS, ...) have no columnId
        print("THE-%s | %s | %s" % (c["sequentialId"], cols.get(c.get("columnId"),"?"), c["name"]))' \
  "$(fav "columns?widgetCommonId=$W")"
```

Paging: responses carry `pages`, `limit` (100) and `requestId`; ask for `page=N&requestId=<id>`
to stay on one snapshot. `collectionId=5d907e7ad6010016b8547901` instead of
`widgetCommonId` spans all three boards.

## Resolving the opaque IDs

| Field | Resolve with |
|---|---|
| `assignments[].userId`, `createdByUserId`, comment `userId` | `fav users` (`userId`, `name`, `email`). `HLuBf2ii3PqwkYmyD` = *Clippy* bot `dev@starweb.se`, files cards from Slack |
| `tags[]` | `fav tags` (`qn5L7rM5TrqgvhyAg` = *NEH*, `MWAS5JFzr4XziRLQL` = *Investigation*) |
| `columnId` / `widgetCommonId` / `collectionId` | `fav "columns?widgetCommonId=<board>"` / `fav "widgets/<id>"` / `fav collections` |
| `customFields[]` | `fav customfields` (14 pages). The entry with `link` is the Slack thread (`#dev-support`); plain `value` strings are shop name and reporter |
