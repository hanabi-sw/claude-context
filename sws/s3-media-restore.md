# SWS media files in S3 — querying the bucket and restoring deleted files

SWS only. Read when shop images, media-library files or their cached sizes are missing, were
deleted (Duplicates filter, bulk delete, mistaken cleanup), or when something needs to be looked up
in the static-assets bucket. Read-only from Claude; the restore itself is a human-run command.
Verified against sws-6@9f1e4e1 and the live bucket on 2026-10-26.

## The bucket

- `starweb-static-production`, account `546532984119`. The low-priv profile can list and read
  versions; it has no `s3:DeleteObjectVersion`, so a restore is handed over (see `../tokens.md`).
- **Versioning is enabled.** A media-library delete writes a *delete marker* on top of the previous
  version; the bytes stay. Lifecycle rule `one-rule-to-rule-them-all`: noncurrent versions expire
  after **30 days**, expired markers are swept. A restore has a 30-day window from the deletion.
- Key layout (`app/src/Shop/Model/Media/AbstractMediaFile.php:129`, `ImageFile/ImageFile.php:185,249`):
  - originals: `public/shops/<idCode>/files/<name>`
  - cached sizes: `public/shops/<idCode>/files/cache/<name>_<size>.<ext>`, eight sizes
    (`ImageFile::$namesAndResolutions`: original, gigante, grande, large, medium, small, tiny, micro).
    Cached sizes regenerate on demand from the original, so restoring them is optional.
- Deleting a media file (`MediaFileDbService::delete()`) removes the DB row, the original, all cached
  sizes, and rewrites the products' media links. S3 keeps the versions; the DB does not.

## Read-only queries

```sh
B=starweb-static-production; P=public/shops/<idCode>/files/
aws s3api get-bucket-versioning --bucket $B                       # expect Status Enabled
aws s3api get-bucket-lifecycle-configuration --bucket $B          # the 30-day rule
aws s3api list-objects-v2 --bucket $B --prefix public/shops/ --delimiter / \
  --query 'CommonPrefixes[].Prefix' --output text | tr '\t' '\n' | grep -i <shop>   # find the idCode
# every delete marker written on/after a date, for the whole shop (originals + cache) — slow, paginates
aws s3api list-object-versions --bucket $B --prefix $P \
  --query 'DeleteMarkers[?LastModified>=`2026-10-26`].{Key:Key,VersionId:VersionId,IsLatest:IsLatest,LastModified:LastModified}' \
  --output json > markers.json
# history of one key: versions behind the marker, their dates and sizes
aws s3api list-object-versions --bucket $B --prefix "$P<name>" \
  --query '{versions:length(Versions||`[]`),markers:length(DeleteMarkers||`[]`),latest:Versions[0].LastModified,size:Versions[0].Size}'
```

- `--prefix` is a prefix, not an exact key: `foo.jpg` also matches `foo.jpg.bak`. Filter on `Key` afterwards.
- A whole-shop `files/` listing includes `files/cache/` (8× the originals); split them in post-processing.
  For a ~1k-file shop deletion the call took minutes; run it in the background.
- `LastModified` on a marker is the deletion time (UTC). A per-minute histogram gives the timeline.
- A key can carry **two markers with the same timestamp** (double delete call); the second one is
  `IsLatest: false`. Both must be removed or the key stays deleted. Check `Versions[?LastModified>=date]`
  on affected keys before restoring: a newer upload on top means the merchant already fixed that file.

## Restore recipe (hand-over)

From `markers.json`, build `delete-objects` batches of ≤1000 `{Key, VersionId}` pairs, **markers only**
(never a `Versions[]` id — that deletes data for good), originals first, cache optional:

```sh
aws s3api delete-objects --bucket $B --delete file://restore-originals-00.json   # {"Objects":[...],"Quiet":true}
aws s3api list-object-versions --bucket $B --prefix $P --query 'length(DeleteMarkers[?LastModified>=`<date>`])'  # expect 0
```

Then the DB side, in the Notion how-to **"Restore shop's deleted media files"** (SWS → Tasks,
`https://www.notion.so/3040c9e6c00b4aec8734ee784ea531a2`): tables `media_files`, `media_files_langs`,
`media_file_categories`, `products_media_files` from the per-table backup before the deletion, scoped
to the restored filenames; then `bin/console clear-cache -s <shopId>` and `bin/console es:rebuild-shop <shopId>`.
The Notion page's script `scripts/restore-sws-media-files.php` in `starweb/docker-lambda-etc` (SSH clone
only, `gh-ro` gets 403) does the same marker removal per filename, but prefix-matches, takes the first
marker without `IsLatest`/date checks, misses double markers, and knows six of the eight sizes. Prefer
the listing-driven batches above.

## Reference incident

2026-10-26, shop `hobbyland` (#779): Duplicates filter + "select all pages" deleted every `_dup*` image,
1016 originals / 7264 cached sizes, markers 10:21–10:27 UTC, 27 keys double-marked, no uploads that day.
Restore window closes ~2026-11-25.
