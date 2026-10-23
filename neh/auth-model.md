# NEH auth model

NEH only. Read when reasoning about who can reach an NEH URL: how requests are authenticated on a
shop host, which surfaces are unauthenticated by design, and the Apache merge-order traps that make
some access-control mechanisms silently ineffective.
Verified against `neh@fdf7fa8` (develop), `neh-infrastructure@3d814a5` (develop) and
`neh-plugins` `origin/se-admin` on 2026-10-23.

## The authenticated Locations

All defined per vhost in `neh/apache/Includes/SE_shop-ssl.inc` (HTTPS). The HTTP include
`SE_shop.inc` is 13 lines and defines **none** of them.

| Location | Scheme |
|---|---|
| `/admin` (ssl.inc:45-60) | `AuthType SE::ShopCenter`, `PerlAuthenHandler SE::ShopCenter->authenticate`, `require admin` |
| `/admin/SYS` | same, declared in `apache/Includes/SE/SE_100_www.conf:18-30` with `require valid sysadmin` (2.2) / `require admin` (2.4) |
| `/LOGIN`, `/LOGOUT` (30-42) | `AuthType SE::ShopCenter` |
| `/DAV`, `/SOAP` (62-92) | `AuthType Basic`, `PerlAuthenHandler SE::ShopCenter::admin_Auth_plain` |
| `/__API__/` (94-98) | `AuthType Basic` with no provider and no `Require` — Apache enforces nothing; the real gate is an Ansible-managed rewrite in `shopexpo.conf:85-94` returning 401 when `Authorization` is empty, plus the credential check in `SE_sys/code/API.pm:419` |

`SE::ShopCenter` and `SE::Auth2_4` subclass `Apache2::AuthCookie` / `Apache2_4::AuthCookie`;
there is no local override of `authenticate` or `authorize`. The repo supplies only the hook methods.

## Why `/admin` fails closed

`require admin` resolves to `SE::Auth2_4::authz_admin` (`Auth2_4.pm:61-92`), registered by
`PerlAddAuthzProvider admin SE::Auth2_4->authz_admin` (ssl.inc:25, SE_100_www.conf:13). It returns
`AUTHZ_DENIED_NO_USER` whenever `$r->user` is empty, then `AUTHZ_GRANTED` only if
`SE::DB::authz_admin` approves, else `AUTHZ_DENIED`. **No `is_initial_req` short-circuit and no
`return OK`** — on a subrequest, internal redirect or `ErrorDocument`, authorization still runs
and denies. (`AUTHZ_DENIED_NO_USER` is missing from the `-compile` list at `Auth2_4.pm:13`; minor.)

Early `return OK` paths exist elsewhere and all fail closed or sit off `/admin`: in the Apache 2.4
authz provider ABI `AUTHZ_DENIED == 0 == Apache2::Const::OK`, so `authz_soap`'s
`return Apache2::Const::OK unless $r->is_initial_req` (`:106`) is *denied*, not granted.
`authz_dav` (`:130`) has a truncated constant (`return Apache2::Const::` — a bare package token
coercing to 0), also denied; clearly a typo, still unfixed.

`authen_ses_key` (`ShopCenter.pm:811-822`) returns `''` (defined) rather than `undef` on a failed
cookie. Safe only because `authz_admin` re-checks `$r->user`. Still unhardened.

## Merge-order trap: `<Location>` holds, `<Files>` and `<Directory>` may not

Two independent reasons, and only the first one is universal:

1. **`AuthMerging Off` (default).** `<Files>` merges *before* `<Location>`, and the later section
   *replaces* the earlier one, so `<Location /admin>`'s `require admin` overrides any
   `<Files "x">` rule under `/admin/`. This is why the awstats restriction, historically a
   `<Files "awstats.pl">`, never held on `/admin/awstats/*`. It is now
   `<LocationMatch "^(?!/admin/awstats/).*awstats\.pl"> Require local` + VPN ranges in
   `neh-infrastructure/roles/neh-install/templates/awstats-restrict.conf.j2`, deployed to
   `conf-enabled/awstats-restrict.conf` (customers legitimately use awstats through the admin
   "Webbstatistik" page; every other route to the CGI is denied).
2. **Map-to-storage short-circuit.** `SE::ShopCenter::handler` is a `PerlMapToStorageHandler`
   (`SE_shop*.inc:8`, `ShopCenter.pm:185`). On the `__SYS__`, `PICTURE`, `__SETCOOKIE__`,
   error-404, SEO-redirect and `/admin/plugin/` branches it sets `$r->filename` and returns `OK`,
   which makes httpd skip the core `map_to_storage` and therefore `ap_directory_walk` /
   `ap_file_walk`: `<Directory>`, `<Files>`, `<FilesMatch>` and `.htaccess` are not applied on
   those requests. `ap_location_walk` runs afterwards regardless. The generic `/admin/` and
   `/admin/awstats` branches mostly fall through to `DECLINED` (`:524`), so the file walk *does*
   run there — reason 1 is what bites on `/admin`.

Consequence either way: **any access control that must hold on `/admin` has to be a
Location-type section.** The PHP kill-switch and the `/admin/` PHP allowlist are `<LocationMatch>`
for this reason.

A second ordering fact: server-level `conf-enabled/*.conf` is read before `sites-enabled`
(`shopexpo.conf` lands in `sites-enabled/000-shopexpo.conf`), so a server-level Location merges
*before* a vhost Location. A server-level rule cannot override `<Location /admin>`; it must avoid
overlapping it.

## Unauthenticated by design

- **Payment and webhook callbacks**, registered with `GLOBAL_add_post_handler(..., auth => "ANY")`
  and dispatched from the unauthenticated storefront path, triggered by **query parameter** on the
  shop root: `?SCO_PUSH=` (Svea), `?NETSEASY_WH_*=` (Nets Easy), `?PAYMENT_CALLBACK=`,
  `?CERTITRADE_RESULT=`, `?DIBS_CALLBACK=`, `?PAYNOVA_CALLBACK=`, `?NB_MAC=`, `?PAYPAL_NOTIFY=`
  (`Pay.pm` ~64-77, `PayMethod.pm:73`, `PayMethod/SVEACHECKOUT.pm:54`,
  `PayMethod/NETSEASY/NetsEasyAPI.pm:30-42`). `?JSON=` handlers are a separate mechanism,
  `GLOBAL_add_json_handler(name, func, auth => …)` (`DButil.pm:322-332`) with auth set per handler.
  **None are under `/admin` and none are `.php`**, so extension-based denies cannot break them.
- **Default is `ANY`.** `__add_post_handler` defaults to `auth => "ANY"` when the caller passes
  none (`DButil.pm:219`). Handlers registered without an explicit auth are therefore
  unauthenticated even when they look admin-ish — e.g. `Admin.pm:74-76` (`SEO_METADATA_EDIT`,
  `STOCKPROFILE_EDIT`, `ONBOARDING_LOGO`) and `Pay.pm:58` (`paymentrescue_list`, JSON, `ANY`).
  Worth a look; not confirmed exploitable.
- **`/TellusPay/`** — the one path-based callback, `$r->uri =~ m|/TellusPay/|` (`ShopCenter.pm:376`).
- **Storefront paths** — `/`, `/cart.html`, `/create-order.html`, `/PICTURE/…`, `/__SYS__/…`,
  `/__SETCOOKIE__/…`, `/__CART__/…`, `/__JWS__/…`, `/LOGIN`, `/LOGOUT`.
- **`.well-known`** — exempted from the dotfile 404 and given `Content-Type: text/plain` for
  Apple Pay. Grants nothing and never matches `/admin`. The one genuine pre-auth grant,
  `<Directory /usr/share/phpmyadmin/.well-known> Require all granted`, exists only on the dev-only
  phpMyAdmin vhost (`phpmyadmin_state: present`).

## The multiserver admin-token login

A password-less route into `/admin`, used by in-house staff to reach customer servers:

1. **Mint** — `POST /__API__/multiserver/shop/<shop>/adminlogintoken` (`API/MultiServer.pm:275-279`,
   `right => "MultiServer"`; `superrights` on the `APIUser` also passes, `API.pm:507`). Inserts a
   120-character random token into `DB_MASTER.MS_AdminLoginToken` (`token varchar(128)`),
   hardcoded `admin_id=1` (`MultiServer.pm:797-798`). Second mint path: the CLI
   `SE_sys/apps/distribute.pl:237-248`, also `admin_id=1`.
2. **Redeem** — `GET https://<masterdomain>?MS_ADMIN_TOKEN_LOGIN=<token>` on the **shop root,
   outside `/admin`, no auth** (`ph_MS_ADMIN_TOKEN_LOGIN`, `auth => "ANY"`, `MultiServer.pm:17`).
   Sets the `admid` and `sess` cookies to `&MST&:<token>` and redirects to `destination`
   (default `/admin`) (`:820-842`). **Redeeming does not consume the token.**
3. **Use** — `authen_ses_key` splits the cookie, `SE::DB::auth_admin` takes the `&MST&` branch and
   validates the token against an 8-hour window (`SE/DB.pm:933-943`); `authz_admin` grants.
   Tokens are purged after 1 day.

Delegated SSO rather than a bypass, but: the token travels in a URL query string (referrer, proxy
and history logging), is reusable for 8 hours, `admin_id` is hardcoded, and `destination` is an
attacker-suppliable redirect target at mint time. The documented defence `MS_ADMIN_LOGIN_IP_ALLOW`
exists only as a commented example in
`neh-infrastructure/roles/neh-install/templates/shopexpo.conf.j2:139` and **is not implemented
anywhere in the application**.

The `se-admin` branch of `neh-plugins` holds the in-house multiserver admin (Perl, e.g.
`code/www/MultiServer.pm`, plus HTML/JS). **Zero PHP.** Side finding: that branch has
`code/www/KlarnaV3Onboarding/{production,playground}.private.key` committed.

## Dispatcher vs Apache disagree on what "admin" means

`<Location /admin>` is prefix-anchored and segment-aware, so it matches `/admin` and `/admin/...`
only. The dispatcher matches `m|/admin/|` **unanchored** (`ShopCenter.pm:334`), so
`https://shop/anything/admin/x.html` reaches `admin_response_handler` with no `<Location /admin>`
match and therefore no auth. Contained by `sbshop_filetype()` (`:1436-1442`), which only accepts
`text/html`, `.scss`, `robots.txt` and `robots.txt.SSL` — `.php` is declined — and by the file
having to exist in the shop's own webroot. Not a PHP bypass, but an unauthenticated entry into the
admin code path. CrowdSec's config already uses `(^|/)admin(/|$)` for this reason.

## Other weaknesses worth knowing

- **CrowdSec is off on `(^|/)admin(/|$)`, `^/__API__/` and `(^|/)LOGIN(/|$)`**
  (`roles/crowdsec/defaults/main.yml:240-243`, because of a false-403 bug in the pinned
  mod_crowdsec build), so the admin login form and the API have no L7 ban enforcement in front.
- **The HTTP vhost has no `/admin` protection at all.** Plaintext safety depends entirely on an
  Ansible-injected global SSL redirect blockinfile into `SE_shop.inc` that has **no custom marker**
  (`tasks/main.yml:1778-1786`). The filesystem target on HTTP would be the shop's own webroot, not
  `SE_sys/admin`, so not a PHP disclosure — but an unauthenticated entry into the admin dispatcher
  if that block is ever missing.
- **`Options +FollowSymLinks`** (not `SymLinksIfOwnerMatch`) on `<Directory "/home/www">`
  (`shopexpo.conf:19-20`): a shop that can write its own webroot via DAV, FTP or the admin file
  manager can symlink into `/home/www/SE_sys/admin`. The URL would not start with `/admin`, so
  neither the Location auth nor `php_admin_flag engine on` applies — raw source disclosure, not
  execution.
- **Credential storage**: admin passwords use MySQL's legacy unsalted `PASSWORD()`
  (`ShopCenter.pm:765`, `SE/DB.pm:962`); `APIUser` passwords are compared as stored plaintext
  (`API.pm:419-420`, `varchar(64)`).
- **nginx static caching on elbutik — live exposure.** The `neh-nginx-proxy` role caches
  `~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff)$` keyed on `$request_uri` with no auth in the key.
  The opt-in variant E (`neh_nginx_proxy_optin_static_cookie_enabled`) adds
  `proxy_ignore_headers Set-Cookie` + `proxy_hide_header Set-Cookie` and has no `/admin`
  exclusion (`templates/nginx/snippets/neh-opt-in.conf.j2:15-56`). That flag is **`true` on
  `nehprod-elbutik-tx` and `nehdev-elbutik-dev-tx` since 2026-10-08** (commit e953bae), so an
  authenticated 200 for `/admin/**.js|css|png` is cacheable and servable to anonymous clients
  there today. Fix candidates: exclude `^/admin/` from variant E, or add `$cookie_admid` to the key.
