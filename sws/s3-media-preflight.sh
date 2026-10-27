#!/usr/bin/env bash
# s3-media-preflight.sh — READ-ONLY identification + pre-flight for restoring deleted SWS media
# files from S3 versioning. Companion to s3-media-restore.md. Makes NO write call to AWS, ever.
#
# Usage:
#   s3-media-preflight.sh <shopIdCode> <windowStart> <windowEnd> [manifestDir|-] [outDir]
#
#   shopIdCode   the shop's idCode == its S3 prefix segment (public/shops/<idCode>/files/)
#   windowStart  ISO 8601 UTC with offset, e.g. 2026-10-26T10:21:00+00:00  (the deletion window)
#   windowEnd    same form; markers with LastModified inside [start, end] are the deletion
#   manifestDir  directory holding restore-originals-*.json / restore-cache-*.json to PROVE.
#                Omit or pass "-" to run in BUILD mode: the script writes those manifests into outDir
#                from the window markers (and nothing else), ready for a second run that proves them.
#   outDir       where snapshot-before.json, the exception lists and (build mode) the manifests go.
#                Default: current directory. Never pass a directory you must not write to.
#
# Env:  BUCKET   default starweb-static-production
#       PATTERN  optional regex every ORIGINAL marker key must match (e.g. '_dup[a-z0-9]{5}[0-9]+\.')
#                — a non-matching key fails the pre-flight, because the manifests then cover more
#                than the deletion you think you are undoing.
#
# Exit 0 only on "PRE-FLIGHT OK" (prove mode) or "BUILD OK" (build mode). Any other exit: stop, read.
#
# Credentials: works with the read-only low-priv role. It needs s3:GetBucketVersioning,
# s3:GetLifecycleConfiguration and s3:ListBucketVersions on the bucket. Nothing more.
set -euo pipefail

SHOP=${1:?shopIdCode}; WS=${2:?windowStart}; WE=${3:?windowEnd}
MAN=${4:--}; OUT=${5:-.}
B=${BUCKET:-starweb-static-production}
P="public/shops/${SHOP}/files/"
PATTERN=${PATTERN:-}
mkdir -p "$OUT"
SNAP="$OUT/snapshot-before.json"

echo "[1/3] bucket: $B  prefix: $P  window: $WS .. $WE  mode: $([ "$MAN" = - ] && echo BUILD || echo PROVE)"
aws s3api get-bucket-versioning --bucket "$B" --query Status --output text | grep -qx Enabled \
  || { echo "versioning is not Enabled on $B — there is nothing to restore from"; exit 2; }
echo "lifecycle NoncurrentDays: $(aws s3api get-bucket-lifecycle-configuration --bucket "$B" \
  --query 'Rules[].NoncurrentVersionExpiration.NoncurrentDays' --output text)  (restore window after a deletion)"

echo "[2/3] full version listing of $P -> $SNAP  (one call, paginates; minutes for a large shop)"
aws s3api list-object-versions --bucket "$B" --prefix "$P" --output json > "$SNAP"

echo "[3/3] checks"
python3 -I - "$SNAP" "$WS" "$WE" "$P" "$MAN" "$OUT" "$PATTERN" <<'PY'
import json, sys, glob, re, os, collections
snap, ws, we, prefix, man_dir, out, pattern = sys.argv[1:8]
d = json.load(open(snap))
markers = d.get("DeleteMarkers", []); versions = d.get("Versions", [])
cache = lambda k: "/files/cache/" in k
fail = []

# --- identification: what the bucket says was deleted in the window --------------------------
win = {(m["Key"], m["VersionId"]): m for m in markers
       if ws <= m["LastModified"] <= we and m["Key"].startswith(prefix)}
orig = [m for m in win.values() if not cache(m["Key"])]
cach = [m for m in win.values() if cache(m["Key"])]
orig_keys = {m["Key"] for m in orig}
dbl = sorted(k for k, c in collections.Counter(m["Key"] for m in orig).items() if c > 1)
hist = collections.Counter(m["LastModified"][11:16] for m in orig)
print(f"snapshot: {len(versions)} object versions, {len(markers)} delete markers under {prefix}")
print(f"window markers: {len(win)} = originals {len(orig)} on {len(orig_keys)} keys (+{len(dbl)} keys double-marked), cache {len(cach)}")
if orig:
    print("originals deleted per minute (UTC): " + " ".join(f"{k}:{v}" for k, v in sorted(hist.items())))
    print(f"first/last original marker: {min(m['LastModified'] for m in orig)} / {max(m['LastModified'] for m in orig)}")
other = [m for m in markers if (m["Key"], m["VersionId"]) not in win]
print(f"markers under the prefix OUTSIDE the window (not touched by this restore): {len(other)}")
if pattern:
    bad = sorted({m["Key"] for m in orig if not re.search(pattern, m["Key"])})
    if bad: fail.append(f"{len(bad)} original markers in the window do not match PATTERN {pattern!r}: {bad[:3]}")

# --- uploads: anything newer than a marker, and anything new under the whole prefix ----------
by_key = collections.defaultdict(list)
for v in versions: by_key[v["Key"]].append(v)
newer, noprior = [], []
for k in sorted(orig_keys):
    mk_time = max(m["LastModified"] for (kk, _), m in win.items() if kk == k)
    vs = by_key.get(k, [])
    if not vs: noprior.append(k); continue
    if any(v["LastModified"] > mk_time for v in vs): newer.append(k)
day = ws[:10]
uploads_today = [v for v in versions if v["LastModified"] >= day and not cache(v["Key"])]
after = [v for v in uploads_today if v["LastModified"] > we]
open(os.path.join(out, "keys-with-newer-upload.txt"), "w").write("".join(k + "\n" for k in newer))
open(os.path.join(out, "keys-without-prior-version.txt"), "w").write("".join(k + "\n" for k in noprior))
print(f"original keys with an upload NEWER than their marker (merchant re-fixed, excluded): {len(newer)}")
print(f"original keys with NO prior version (truly lost, nothing to restore): {len(noprior)}")
print(f"originals uploaded under the prefix since {day}: {len(uploads_today)}, of which after the window: {len(after)}"
      "  <- tell the DB side: these rows/links must survive the import")
if noprior: fail.append(f"{len(noprior)} keys have no prior version -> keys-without-prior-version.txt")

def write_manifests(name, items):
    n = 0
    for i in range(0, len(items), 1000):
        with open(os.path.join(out, f"{name}-{i//1000:02d}.json"), "w") as f:
            json.dump({"Objects": [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in items[i:i+1000]],
                       "Quiet": True}, f)
        n += 1
    return n

if man_dir == "-":
    # --- BUILD mode: manifests from the listing, markers only, excluding keys with a newer upload --
    keep = lambda m: m["Key"] not in set(newer)
    o = sorted([m for m in orig if keep(m)], key=lambda m: m["Key"])
    stems = {k.rsplit("/", 1)[1].rsplit(".", 1)[0] + "_" for k in orig_keys if k not in set(newer)}
    c = sorted([m for m in cach if m["Key"].rsplit("/", 1)[1].startswith(tuple(stems))], key=lambda m: m["Key"])
    no = write_manifests("restore-originals", o); nc = write_manifests("restore-cache", c)
    with open(os.path.join(out, "restore-originals.txt"), "w") as f:
        f.write("".join(n + "\n" for n in sorted({m["Key"].rsplit("/", 1)[1] for m in o})))
    pilot = []
    for k in dbl[:2]: pilot += [m for m in o if m["Key"] == k]
    seen = {m["Key"] for m in pilot}
    for m in o:
        if len(pilot) >= 14: break
        if m["Key"] not in seen: seen.add(m["Key"]); pilot.append(m)
    with open(os.path.join(out, "restore-pilot.json"), "w") as f:
        json.dump({"Objects": [{"Key": m["Key"], "VersionId": m["VersionId"]} for m in pilot], "Quiet": False}, f, indent=1)
    print(f"\nBUILD: wrote {no} originals manifest(s) ({len(o)} markers), {nc} cache manifest(s) ({len(c)} markers), "
          f"restore-pilot.json ({len(pilot)} ids on {len(seen)} keys), restore-originals.txt into {out}")
    if not o: fail.append("no original markers in the window: wrong window/shop, or already restored")
    if fail:
        print("\nBUILD FAILED:"); [print(" -", f) for f in fail]; sys.exit(1)
    print("BUILD OK — now run this script again with manifestDir=" + out + " to PROVE the manifests before any write.")
    sys.exit(0)

# --- PROVE mode: the manifests must be exactly the window's markers and nothing else ----------
man = {}
for f in sorted(glob.glob(os.path.join(man_dir, "restore-originals-*.json")) + glob.glob(os.path.join(man_dir, "restore-cache-*.json"))):
    for o in json.load(open(f))["Objects"]: man[(o["Key"], o["VersionId"])] = os.path.basename(f)
pf = os.path.join(man_dir, "restore-pilot.json")
pilot = {(o["Key"], o["VersionId"]) for o in json.load(open(pf))["Objects"]} if os.path.exists(pf) else set()
if not man: fail.append(f"no restore-*.json manifests found in {man_dir}")
if pilot and not pilot <= set(man): fail.append("restore-pilot.json contains ids that are not in the full manifests")
only_man = set(man) - set(win); only_win = set(win) - set(man)
if only_man:
    hint = " (window has NO markers at all: already restored?)" if not win else ""
    fail.append(f"{len(only_man)} manifest ids are NOT delete markers inside the window{hint}; first: {sorted(only_man)[:2]}")
only_win_orig = {kv for kv in only_win if not cache(kv[0]) and kv[0] not in set(newer)}
if only_win_orig: fail.append(f"{len(only_win_orig)} original markers in the window are missing from the manifests; first: {sorted(only_win_orig)[:2]}")
ver_ids = {(v["Key"], v["VersionId"]) for v in versions}
if set(man) & ver_ids: fail.append("manifest contains REAL object version ids — running it would destroy data. Never run it.")
man_keys = {k for k, _ in man}
if any(not k.startswith(prefix) for k in man_keys): fail.append("manifest contains keys outside the shop prefix")
if set(newer) & man_keys: fail.append(f"{len(set(newer) & man_keys)} manifest keys have a newer upload — rebuild the manifests")
print(f"manifest ids: {len(man)} in {len(set(man.values()))} file(s); pilot ids: {len(pilot)}")
if fail:
    print("\nPRE-FLIGHT FAILED:"); [print(" -", f) for f in fail]; sys.exit(1)
print("\nPRE-FLIGHT OK — the manifests are exactly the delete markers of this window under this prefix; "
      "every key has an intact prior version and no newer upload. Safe to hand over for the writes.")
PY
