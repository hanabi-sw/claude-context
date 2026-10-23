# sws-6 — local Docker dev env & tests

> **Unverified on the NEH workstation; last verified unknown** (date from the text itself) — see `../HANDOVER-sws.md`. SWS only. Read when setting up or repairing the sws-6 local Docker dev env or running its PHPUnit suites.

Checkout: `~/code/sws-6`. Full detail in its `CLAUDE.md`, `docs/DOCKER.md`, `docs/WORKTREES.md`.
Every `task`/`docker` call needs `dangerouslyDisableSandbox: true` (Docker socket).

## Bring-up (main checkout, once)

```bash
# 1. Docker Hub login — sws6-app-dev, sws6-app-base and oauth-server are private (see ../tokens.md)
set -a; . ~/.tokens/dockerhub; set +a; echo "$TOKEN" | docker login --username "$USERNAME" --password-stdin
# 2. go-task — not a system package here; installed via mise, symlinked onto PATH
mise use -g task@latest && ln -sfn "$(mise which task)" ~/.local/bin/task
# 3. compose expects an external network; the provision script also creates it, `docker compose up` alone does not
docker network create starweb 2>/dev/null || true
# 4. provision: pulls images, composer/npm install, frontend compile, app DB + devShop seed, ES index (~10–20 min cold)
cd ~/code/sws-6 && task dev:provision          # .env is copied from .env.example if missing
task dev:status                                # expect 8/8 running, 4 ✓
```

Hosts file (browser access only, not needed for tests):
`127.0.0.1 sws.local dev-shop.sws.local www.dev-shop.local static.sws.local scs.local`

## Daily

```bash
task dev:start | dev:stop | dev:shell | dev:status
task dev:console -- migrate            # bin/console inside sws-app
```

## Tests (all run inside sws-app)

```bash
task test:unit
task test:integration                  # FULL suite via paratest, 2 workers, stop on first failure, excludes @group performance — slow, only when asked
task test:integration -- tests/integration/app/src/Shop/Model/Menu   # same runner scoped to a dir (verified: 6 tests ≈ 1 min incl. baselines)
PARATEST_WORKERS=4 task test:integration
task test:backend:specific -- tests/integration/path/SomeTest.php
task test:backend:specific -- --filter testName tests/integration/path/SomeTest.php
task test:clean                        # drop test_shop*/test_shops* DBs + ES indices after a crashed run
```

Integration tests build their own `test_shop`/`test_shops` baseline on first run (~40 s for a
single-file run, once per paratest worker per run); they need mysql, redis and elasticsearch up,
nothing else. A one-test file therefore takes ~45 s wall clock, not the 0.03 s of a unit test.
Snapshot log: `data/test-reports/snapshot-<worker>.log`.

## Gotchas

- `pull access denied` / `no such manifest` on `starweb/*` → Docker Hub login missing (step 1).
- `network starweb declared as external, but could not be found` → step 3.
- `task: command not found` → step 2; mise shims are not on PATH in this shell, hence the symlink.
- `Error response from daemon: network with name starweb already exists` during provision is harmless (`|| true`).
- `npm ERR! code ERR_SOCKET_TIMEOUT` in the npm step (slow link, ~2 MB/s here) aborts the provision.
  Raise npm's budgets in the container and rerun — node_modules is kept, so `npm install` resumes:
  `docker exec sws-app npm config set fetch-retries 10 fetch-retry-maxtimeout 300000 fetch-timeout 900000 maxsockets 4`
  then `task dev:provision` again. The setting lives in the container and is lost on `--force-recreate`.
- `npm ERR! code ENOTEMPTY … rename node_modules/<pkg> -> node_modules/.<pkg>-xxxx` after an aborted
  `npm ci`: the tree is half-written, `npm install` cannot reconcile it. Run `task dev:provision -- --clean-npm`.
- Ports 80, 3306, 6379, 9200, 9324, 1080, 1025, 5601 must be free on the host.
- Provision runs as root in the container; it ends with `chown -R www-data data public/shops`.
  If Apache 500s on a template render later, rerun that chown via `task dev:shell`.
- `bin/console` does not propagate exit codes — the provision script verifies steps against the DB instead.
- Worktrees: never run `dev:provision` there (it refuses); use `task wt:provision -- <slot> <n>`.
- Don't run the full suites unprompted; they are slow. Prefer `test:backend:specific`.
