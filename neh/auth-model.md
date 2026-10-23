# NEH auth model

How requests are authenticated on an NEH (Nordisk eHandel) shop host, which surfaces are
unauthenticated by design, and the Apache merge-order traps that make some access-control
mechanisms silently ineffective. NEH platform only.

Repos referenced: `neh` (the Perl shopexpo codebase), `ansible` (deploys).

## The authenticated Locations

All defined per-vhost in `neh/apache/Includes/SE_shop-ssl.inc` (HTTPS) — the HTTP include
`SE_shop.inc` is 13 lines and defines **none** of them.

| Location | Scheme |
|---|---|
| `/admin` | `AuthType SE::ShopCenter`, `PerlAuthenHandler SE::ShopCenter->authenticate`, `require admin` |
| `/admin/SYS` | same, declared in `SE_100_www.conf` with `require valid sysadmin` (2.2) / `require admin` (2.4) |
| `/LOGIN`, `/LOGOUT` | `AuthType SE::ShopCenter` |
| `/DAV`, `/SOAP` | `AuthType Basic`, `PerlAuthenHandler SE::ShopCenter::admin_Auth_plain` |
| `/__API__/` | `AuthType Basic` with no provider and no `Require` — Apache enforces nothing; the real gate is a rewrite returning 401 when `Authorization` is empty, plus credential checks in `API.pm` |

`SE::ShopCenter` and `SE::Auth2_4` both subclass `Apache2::AuthCookie` / `Apache2_4::AuthCookie`;
there is no local override of `authenticate` or `authorize`. The repo supplies only the hook
methods.

## Why `/admin` fails closed

`require admin` resolves to `SE::Auth2_4::authz_admin`, registered by
`PerlAddAuthzProvider admin SE::Auth2_4->authz_admin`. It returns
`AUTHZ_DENIED_NO_USER` whenever `$r->user` is empty, then `AUTHZ_GRANTED` only if
`SE::DB::authz_admin` approves, else `AUTHZ_DENIED`. **There is no `is_initial_req`
short-circuit and no `return OK`** — so even on a subrequest, internal redirect or
`ErrorDocument`, authorization still runs and denies.

Early `return OK` paths do exist elsewhere in the auth code, and all of them fail closed or are
off `/admin`: in the Apache 2.4 authz provider ABI `AUTHZ_DENIED == 0 == Apache2::Const::OK`, so
`authz_soap`'s `return Apache2::Const::OK unless $r->is_initial_req` is *denied*, not granted.
`authz_dav` has a truncated constant (`return Apache2::Const::` — a bare package token coercing
to 0) which also lands on denied; it is clearly a typo and worth fixing.

`authen_ses_key` returns `''` (defined) rather than `undef` on a failed cookie. That is safe only
because `authz_admin` re-checks `$r->user`. Worth hardening to an explicit `return undef`.

## Merge-order trap: `<Location>` survives, `<Files>` and `<Directory>` do not

`SE::ShopCenter::handler` is a `PerlMapToStorageHandler`. On several branches it sets
`$r->filename` and returns `Apache2::Const::OK`. In httpd that **skips the core
`map_to_storage`, and therefore `ap_directory_walk` and `ap_file_walk`** — so `<Directory>`,
`<Files>`, `<FilesMatch>` and `.htaccess` are not applied on those requests. `ap_location_walk`
runs afterwards regardless, so `<Location>` / `<LocationMatch>` always apply.

Consequences:

- **Any access control that must hold on `/admin` has to be a Location-type section.** This is
  why the PHP kill-switch is a `<LocationMatch>`.
- The awstats restriction was historically a `<Files "awstats.pl">`, which was ineffective twice
  over: skipped on `OK` branches, and — because `<Files>` merges *before* `<Location>` and the
  default `AuthMerging Off` makes the later section *replace* the earlier one — overridden by
  `<Location /admin>`'s `require admin` on `/admin/awstats/*`. It is now a `<LocationMatch>` that
  exempts `/admin/awstats/` (customers legitimately use awstats via the admin "Webbstatistik"
  page) and denies every other route to the CGI.

A second ordering fact: server-level `conf-enabled/*.conf` is read before `sites-enabled`, so a
server-level Location merges *before* a vhost Location. A server-level rule cannot override
`<Location /admin>`; it must avoid overlapping it instead.

## Unauthenticated by design

- **Payment and webhook callbacks.** Registered with `GLOBAL_add_post_handler(..., auth => "ANY")`
  and dispatched from the unauthenticated storefront path. They are triggered by **query
  parameter** on the shop root — `?SCO_PUSH=`, `?NETSEASY_WH_*=`, `?PAYMENT_CALLBACK=`,
  `?JSON=`, `?CERTITRADE_RESULT=` and so on. Providers covered include Svea, Nets Easy, DIBS,
  Paynova, PayEx, PayPal, Klarna, Swedbank Pay, Wasa Kredit, Nordea. **None are under `/admin`
  and none are `.php`**, so extension-based denies cannot break them.
- **`/TellusPay/`** — the one path-based callback, routed by `$r->uri =~ m|/TellusPay/|`.
- **Storefront paths** — `/`, `/cart.html`, `/create-order.html`, `/PICTURE/…`, `/__SYS__/…`,
  `/__SETCOOKIE__/…`, `/__CART__/…`, `/__JWS__/…`, `/LOGIN`, `/LOGOUT`.
- **`.well-known`** — exempted from the dotfile 404 and given `Content-Type: text/plain` for
  Apple Pay. These grant nothing and never match `/admin`. The one genuine pre-auth grant was
  `<Directory /usr/share/phpmyadmin/.well-known> Require all granted` on the PHP-serving
  phpMyAdmin vhost; the PHP kill-switch removes those vhosts.

## The multiserver admin-token login

A password-less route into `/admin`, used by in-house staff to reach customer servers:

1. **Mint** — `POST /__API__/multiserver/shop/<shop>/adminlogintoken`, requiring `APIUser` HTTP
   Basic credentials and the `MultiServer` right. Inserts a 120-character random token into
   `DB_MASTER.MS_AdminLoginToken`, hardcoded to `admin_id=1`.
2. **Redeem** — `GET https://<masterdomain>/?MS_ADMIN_TOKEN_LOGIN=<token>` on the **shop root,
   outside `/admin`, no auth**. Sets the `admid` and `sess` cookies to `&MST&:<token>` and
   redirects to `destination` (default `/admin`).
3. **Use** — `authen_ses_key` splits the cookie, `SE::DB::auth_admin` takes the `&MST&` branch,
   validates the token against an 8-hour window, and `authz_admin` grants.

Delegated SSO rather than a bypass, but note: the token travels in a URL query string
(referrer, proxy and history logging), `admin_id` is hardcoded, and `destination` is an
attacker-suppliable redirect target at mint time. The documented defence
`MS_ADMIN_LOGIN_IP_ALLOW` (commented example in `ansible/roles/neh-install/templates/shopexpo.conf.j2`)
**is not implemented anywhere in the application** — that commented line is its only occurrence
in either repo.

The `se-admin` branch of `neh-plugins` holds the in-house multiserver admin UI. It is all
HTML/JS — **zero PHP**.

## Dispatcher vs Apache disagree on what "admin" means

`<Location /admin>` is prefix-anchored and segment-aware, so it matches `/admin` and `/admin/...`
only. The shop framework dispatcher matches `m|/admin/|` **unanchored**, so
`https://shop/anything/admin/x.html` reaches `admin_response_handler` with no `<Location /admin>`
match and therefore no auth. It is contained by `sbshop_filetype()`, which only accepts
`text/html`, `.scss` and `robots.txt` — `.php` is declined — and by the file having to exist in
the shop's own webroot. Not a PHP bypass, but an unauthenticated entry into the admin code path.
CrowdSec's config already acknowledges this, using `(^|/)admin(/|$)`.

## Other weaknesses worth knowing

- **CrowdSec is off on `(^|/)admin(/|$)`**, `^/__API__/` and `(^|/)LOGIN(/|$)`, so the admin
  login form is the one endpoint with no L7 ban enforcement in front of it.
- **The HTTP vhost has no `/admin` protection at all.** Plaintext safety depends entirely on an
  Ansible-injected global SSL redirect blockinfile that has **no custom marker**. The filesystem
  target on HTTP would be the shop's own webroot, not `SE_sys/admin`, so it is not a PHP
  disclosure — but it is an unauthenticated entry into the admin dispatcher if that block is
  ever missing.
- **`Options +FollowSymLinks`** (not `SymLinksIfOwnerMatch`) on `<Directory "/home/www">`: a shop
  that can write its own webroot via DAV, FTP or the admin file manager can symlink into
  `/home/www/SE_sys/admin`. The URL would not start with `/admin`, so neither the Location auth
  nor `php_admin_flag engine on` would apply — the result is raw source disclosure, not
  execution.
- **Credential storage**: admin passwords use MySQL's legacy unsalted `PASSWORD()`; `APIUser`
  passwords are compared as stored plaintext.
- **nginx static caching** (elbutik hosts only) keys on `$request_uri` with no auth in the key.
  Currently defused by nginx refusing to cache responses carrying `Set-Cookie`, but the opt-in
  variant adds `proxy_ignore_headers Set-Cookie`, which would make authenticated
  `/admin/**.js|css|png` responses servable to anonymous clients.
