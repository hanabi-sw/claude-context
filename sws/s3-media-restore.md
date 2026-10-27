# Restoring deleted SWS media files from S3 — identification, scoped restore, guardrails

SWS only. Read when shop images or media-library files are missing or were deleted (Duplicates filter,
bulk delete, mistaken cleanup) and the files must come back, or when the static-assets bucket must be
queried. Claude is read-only on AWS: every write below is a command the operator runs, after the
read-only pre-flight in `s3-media-preflight.sh` says so.
Verified against sws-6@9f1e4e1 and the live bucket on 2026-10-26 (restore of `hobbyland`, see the tail).

## How media lives in S3

- Bucket `starweb-static-production`, account `546532984119`, region `eu-central-1`. The low-priv
  profile lists and reads versions; it has no `s3:DeleteObjectVersion` (`../tokens.md`).
- **Versioning is enabled.** A media-library delete writes a *delete marker* on top of the previous
  version; the bytes stay. Lifecycle rule `one-rule-to-rule-them-all`: noncurrent versions expire
  **30 days** after they become noncurrent, expired markers are swept. So a deletion is reversible
  for 30 days, after that the file is gone and the marker with it.
- Keys (`sws-6` `app/src/Shop/Model/Media/AbstractMediaFile.php:129`, `ImageFile/ImageFile.php:185,249`):
  originals `public/shops/<idCode>/files/<name>`; cached sizes
  `public/shops/<idCode>/files/cache/<name>_<size>.<ext>`, eight sizes (`ImageFile::$namesAndResolutions`:
  original, gigante, grande, large, medium, small, tiny, micro). The public URL drops `public/`:
  `https://cdn.starwebserver.se/shops/<idCode>/files/...`.
- `MediaFileDbService::delete()` removes the `media_files` row (foreign keys cascade the product,
  variant and category-slideshow links and null the variant/category image columns), deletes the
  original and all cached sizes in S3, then rewrites the surviving product links with new ids. **S3
  keeps the versions; the DB does not.** The DB side is a backup restore, owned by a developer.
- CDN `cdn.starwebserver.se` is CloudFront `E1EU77J69NB7V2` with the bucket as origin. 403/404 are
  cached for 300 s only; no invalidation is needed after a restore.
- Deleting a key that does not exist still writes a marker, so a marker with no version behind it
  means the file was already gone before the deletion.

## The method in one paragraph

The bucket itself is the record of what was deleted: every deleted key carries a delete marker with
the deletion time. Identify the deletion from those markers (prefix + time window + name pattern),
build the `delete-objects` manifests from that same listing, prove the manifests against a fresh
snapshot, pilot a dozen keys, write the batches, diff before/after. Removing a delete marker makes the
previous version current again; it moves no bytes and is undone by deleting the key again. Never work
from a filename list typed in by hand or exported from the ticket.

## Step 1 — identify the deletion from the bucket, not from the ticket

```sh
B=starweb-static-production
aws s3api list-objects-v2 --bucket $B --prefix public/shops/ --delimiter / \
  --query 'CommonPrefixes[].Prefix' --output text | tr '\t' '\n' | grep -i <shopname>
```

Pick the exact idCode: siblings share substrings (`hobbyland`, `klonhobbyland`, `habohobby`), and the
clone shop lives on another DB server. Then run the script in BUILD mode with a generous window
(the whole day works), reading only:

```sh
sws/s3-media-preflight.sh <idCode> 2026-10-26T00:00:00+00:00 2026-10-26T23:59:59+00:00 - /tmp/restore-<idCode>
```

It lists every version and marker under `public/shops/<idCode>/files/` (one call that paginates:
minutes for a large shop, run it in the background; a marker-only `--query` costs the same calls),
and prints the deletion as the bucket saw it: marker count split into originals and cached sizes,
originals per minute, first and last marker, keys with two markers, markers outside the window,
uploads newer than a marker, uploads under the prefix since that day. Read it against the merchant's
story: a continuous run with 1-second gaps is one bulk action; "21 pages" is pages × page size.
Narrow the window to the run (`first/last original marker`, rounded out to the minute), set
`PATTERN` to the name pattern the merchant's action selected on if there is one (the Duplicates filter:
`_dup[a-z0-9]{5}[0-9]+\.`), and run BUILD again. The window and pattern are the scope of the restore.

## Step 2 — the manifests come from the listing

BUILD mode writes into the out dir, and nowhere else:

| File | Holds |
|---|---|
| `restore-originals-NN.json` | `{Objects:[{Key,VersionId}…],Quiet:true}`, ≤1000 per file, every original marker in the window, both markers of a double-marked key |
| `restore-cache-NN.json` | same for the cached sizes of those originals |
| `restore-pilot.json` | ~14 ids on ~12 keys, including both ids of two double-marked keys, verbose |
| `restore-originals.txt` | the filenames, for the DB side |
| `snapshot-before.json` | the full listing the manifests were derived from |
| `keys-with-newer-upload.txt`, `keys-without-prior-version.txt` | exceptions, expected empty |

Every id is a `DeleteMarkers[]` id. A `Versions[]` id in a `delete-objects` call deletes data for good,
and IAM cannot tell the two apart (both are `s3:DeleteObjectVersion`), so this is the one invariant the
pre-flight exists to assert. Keys with an upload newer than their marker are left out: the merchant
already replaced that file. The old `scripts/restore-sws-media-files.php` in `starweb/docker-lambda-etc`
(linked from the Notion how-to, SSH clone only) is not used: it prefix-matches filenames, takes the first
marker without window or `IsLatest` checks, misses the second marker on a key and knows six of the
eight sizes.

## Step 3 — pre-flight, read-only, mandatory, rerun if hours pass

```sh
sws/s3-media-preflight.sh <idCode> <windowStart> <windowEnd> /tmp/restore-<idCode> /tmp/restore-<idCode>
```

PROVE mode takes a fresh snapshot and asserts, exit 0 only when all hold:

- every manifest id is a delete marker inside the window under the shop prefix, and every original
  marker in the window is in the manifests (the manifests are the deletion, no more, no less);
- no manifest id is a real object version;
- every original key has an intact prior version, and none has a version newer than its marker;
- the pilot is a subset of the full manifests; with `PATTERN`, every original matches it.

It also reports uploads under the whole prefix since the deletion day. **That number goes to the DB
side**: those rows and links were made by the merchant after the incident and must survive the
import. (On 2026-10-26 the claim "nothing was uploaded today" was made from a per-key check only and
was wrong by 150 files; the whole-prefix count is what to quote.) A window with zero markers and a
"not delete markers inside the window" failure means the restore already ran.

## Step 4 — scope the write session

Minimum permissions: `s3:ListBucketVersions` on the bucket, `s3:DeleteObjectVersion` and
`s3:GetObjectVersion` on `arn:aws:s3:::starweb-static-production/public/shops/<idCode>/files/*`.
Narrow whatever role the write machine has with an inline session policy carrying exactly those,
then prove the fence: `list-objects-v2` on another shop's prefix must return AccessDenied.

```sh
aws sts assume-role --role-arn arn:aws:iam::546532984119:role/<ROLE> --role-session-name media-restore \
  --duration-seconds 3600 --policy file://session-policy.json
```

What the current IAM setup allows, verified 2026-10-26: `SebastianLockwoodAdmin` does not trust
itself, so a session of that role cannot chain into a narrowed session (`AccessDenied` on
`sts:AssumeRole`); and an `aws-mfa` style `GetSessionToken` session of the IAM user cannot carry a
session policy at all. In practice the fence was unavailable and the writes ran under the admin
session. That is acceptable only because the manifests are machine-derived and proven: the
pre-flight is the real guard, the session policy is defence in depth. A dedicated `media-restore`
role, trusted by the admin role and the developer users, with the permissions above and the prefix
as a parameter, would make the fence routinely available. Not created yet.

## Step 5 — write: pilot, originals, cache, verify

Run on the write machine from the out dir. Each `delete-objects` call takes seconds; the whole
hobbyland restore, 8307 markers in 11 calls, took under a minute of API time.

```sh
B=starweb-static-production
aws s3api delete-objects --bucket $B --delete file://restore-pilot.json      # verbose: each entry DeleteMarker:true, no Errors
# head-object every pilot key: a size and an old LastModified; a Not Found = stop
for f in restore-originals-*.json restore-cache-*.json; do
  printf '%s ... ' "$f"; aws s3api delete-objects --bucket $B --delete file://$f && echo done || { echo FAILED; break; }
done
```

Quiet manifests print nothing on success and an `Errors` array otherwise; stop on it. An id that is
already gone errors without side effect, so a rerun after a partial failure is safe. Verify, read-only:

- window marker count under the prefix is 0, then a `snapshot-after.json` listing diffed against
  `snapshot-before.json`: versions lost 0, versions new 0 unless the merchant uploaded, markers removed
  = manifest count, markers removed outside the manifests 0;
- `head-object` on a random sample of originals and cached sizes;
- one original and one cached-size URL on the CDN return 200 (wait out the 300 s negative cache).

## Step 6 — order with the DB restore and the search index

1. S3 originals. 2. S3 cached sizes. 3. DB import by the developer. 4. Cache clear. 5. Reindex.

The cache batch runs **before** the DB import: `ImageFile::loadResolution()` (`ImageFile.php:263-280`)
trusts the per-size entries in `media_files.meta` and only regenerates a size that `meta` lacks, and
image URLs point straight at the CDN with no fallback route. Restored rows with their old `meta` and
no cached files render as 404s. If the cache batch cannot run first, the developer blanks the per-size
keys in `meta` or runs `bin/console create-thumbnails -s <idCode>` (`-d` for a dry run) after the import.

What the DB side needs from here: `restore-originals.txt`, the pre-deletion per-table backup path under
`s3://starweb-local-backups/databases/<server>/<date>/<db>/` (Notion "Per Table Database Backups"),
the window, the uploads-after-window count, and the rule that the import is insert-only. The Notion
how-to "Restore shop's deleted media files" (SWS → Tasks, `https://www.notion.so/3040c9e6c00b4aec8734ee784ea531a2`)
covers the tables. Links cascade-deleted and re-inserted with new ids must be matched on
`(product_id, media_file_id, type, sort_index)`; `is_duplicate` is a generated column and is never
inserted. Orphan files whose rows are not restored stay in S3 at Starweb's cost; the merchant's quota
is `SUM(size)` over `media_files` rows, so they do not count against it.

Nothing reindexes by itself: a SQL import fires no application event. Then, scoped to the shop and in
this order:

```sh
bin/console clear-cache -s <idCode>                 # category images and theme blocks are cached; products are not
bin/console es:bulk-reindex --shop <idCode> --dry-run
bin/console es:bulk-reindex --shop <idCode>         # in place, no queue; the shop stays browsable
```

Never `clear-cache` without `-s`: that clears every shop on the platform. Prefer `es:bulk-reindex
--shop` over `es:rebuild-shop <idCode>`, which deletes the shop's index first and leaves search and
listings empty until the worker has re-queued every product. `bin/console` always exits 0; read the output.

## Step 7 — which product pages were broken

Prod Elasticsearch is user-run only (`prod-observability.md`). Each product document carries
`imageUrl`, the CDN URL of its display image at medium size, and the index is only rewritten on
product save, so until the reindex it still shows the pre-deletion state. On the shop alias (the
idCode, filtered to the shop automatically):

```sh
ES=https://search-sws-production-74-kc4urq6grrqkotg37i5kusqogm.eu-central-1.es.amazonaws.com
curl -s "$ES/<idCode>/_search?size=10000&filter_path=hits.total,hits.hits._source" -H 'Content-Type: application/json' \
  -d '{"track_total_hits":true,"_source":["id","imageUrl","permalink","name","visibility"],
       "query":{"wildcard":{"imageUrl":{"value":"*/files/cache/*_dup*"}}}}' > es-products.json
```

Match the filename in `imageUrl` against `restore-originals.txt` after stripping the size suffix **and
the `?_=<timestamp>` cache-buster** (the first match attempt forgot it and found nothing). Product page
is `https://<shop domain>/product/<permalink>`. After the reindex the same wildcard count should not
drop, and `{"query":{"bool":{"must_not":{"exists":{"field":"imageUrl"}}}}}` counts imageless products.
Limit: display images only; variant and gallery images need the developer's join of restored media
ids to the link tables.

## Guardrails — read this when in a hurry

- Markers only, never versions. The pre-flight asserts it; nothing else can.
- Scope is prefix + window + pattern, decided from the bucket's own markers. Nothing outside it is
  touched, and the script reports what it leaves alone.
- A prefix listing is not an exact match. Filter on the key afterwards.
- A key can carry two markers from the same second. Remove both or it stays deleted.
- Check for newer uploads per key **and** count uploads across the whole prefix since the deletion.
  The per-key check protects the S3 restore; the prefix count protects the DB import.
- Snapshot before, snapshot after, diff. The diff is the evidence; the write calls' success is not.
- Pilot first, verbose. Batches quiet, stop on `Errors`.
- Rerun the pre-flight if hours pass between proving and writing. It is read-only and costs minutes.
- Freeze the merchant: no uploads, deletes or Duplicates actions until sign-off. Support says it explicitly.
- The clock: 30 days from the deletion. Note the date in the ticket.
- Session narrowed by policy when the IAM setup allows it; when it does not, say so in the hand-over
  instead of pretending.
- Scope every later command to the shop: `-s <idCode>`, `--shop <idCode>`, never bare.
- Cached sizes before the DB import. Say why to the developer.
- S3 restore succeeds silently for rows the developer leaves out; those files become orphans. Decide
  about them after merchant sign-off, never during the restore.
- Everything the operator runs is in a folder that can be copied to the write machine as-is: script,
  manifests, policy, snapshot. No chat history required.

## Reference incident: hobbyland, 2026-10-26 (#779)

The merchant used the media library's Duplicates filter with "select all pages" and deleted every
file matching `_dup[a-z0-9]{5}[0-9]+.<ext>`. That suffix is added on upload when a name is taken and
stays forever, also when the original is later removed; the filter (`is_duplicate` generated column,
`ShopMigration228`) therefore selects "was once uploaded under a taken name", not "has a copy".
The bulk path hard-deletes with no in-use check, confirmation or trash (`MediaController::bulkChangeDeleteAction`).

| | |
|---|---|
| Deletion | 10:21:21–10:27:44 UTC, one continuous run, ~150 originals/minute |
| Markers | 8307: 1043 on 1016 original keys (27 double-marked), 7264 on cached sizes |
| Uploads the same day | 150 originals, 98 of them after the deletion: the merchant's manual repair, 11 replacing deleted files |
| Writes | 11 `delete-objects` calls, 16:08–16:17 UTC, under the admin session (fence unavailable) |
| Verify | diff clean, 60/60 + 30/30 head-object, CDN 200, 0 markers left under the prefix |
| DB side | developer restored rows and links for the 681 files that were linked, left 335 as unused; `es:bulk-reindex` |
| Affected pages | 455 products had a restored file as display image (349 visible); none imageless after the import |
| Pre-deletion backup | `starweb-local-backups/databases/sws-6-2-aurora/2026-10-26T04:29:26Z/hobbyland/` |

Full working set, evidence and outcome: `~/code/ai-plans/hobbyland-media-restore/` (not in git).
