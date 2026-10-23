# Mailgun (Sinch) — NEH shop mail logs — READ-ONLY

NEH only (SWS does not use Mailgun; SWS order mail is `../sws/worker-queue-cron.md`). Read when an
NEH shop e-mail (order confirmation, customer mail, admin copy) does not arrive and postfix on the
shop host already shows `status=sent (250 Great success)` to `smtp.eu.mailgun.org` — from that
point only Mailgun knows what happened.
Verified against `neh@fdf7fa8` (develop) and `neh-infrastructure@3d814a5` (develop) on 2026-10-23;
the `curl` recipes were verified live on 2026-10-12.

**Never do write operations against Mailgun.** Only `GET`: no `POST`, `PUT` or `DELETE`, so no
creating, verifying or deleting domains or keys, no sending mail, no touching suppression lists or
webhooks, whatever the user says. Domains are managed by `mailgunSyncDomains.sh` **on the host**
(itself a writer: it creates domains and DKIM keys, verifies, and resets SMTP passwords — so
"rerun it" is a user-run step too), keys by the user in the dashboard. If a write is needed, give
the user the command to run themselves.

## Token

| | |
|---|---|
| File | `~/.tokens/mailgun` — the **raw key only**, no `VAR=` prefix, trailing newline ok (workstation convention; the host script reads `MAILGUN_KEY` from its environment instead) |
| Load | `K=$(tr -d '[:space:]' < ~/.tokens/mailgun)` |
| Use | `curl -s --user "api:$K" ...` (HTTP basic, user `api`) |
| Creation | user-only, account API key with the **Support** role, see `../tokens.md` |

## Regions and base URLs

NEH shop hosts relay to `[smtp.eu.mailgun.org]:2525`, so shop domains live in the **EU** region.
The same account API key is accepted by both regions, but a domain exists in only one of them;
querying the wrong region gives `404 Domain not found`.

| Region | Base URL |
|---|---|
| EU (all NEH shop domains, 100+) | `https://api.eu.mailgun.net` |
| US (check only if EU returns 404) | `https://api.mailgun.net` |

API timestamps are UTC. The shop host logs in local time (CEST = UTC+2 in summer), so a postfix
line at `16:55:35` is `14:55:35Z` in Mailgun.

## The two sender addresses of a shop

Which From address a mail carries decides the Mailgun domain, the DKIM signature and therefore
where to look.

| Address | Where it is set | Used as |
|---|---|---|
| **Store e-mail** ("E-post till kundtjänst") | admin → Företagsinformation (`SE_sys/admin/shop/company.html:145-154`, which also has a "Validera e-post" DKIM/SPF/DMARC check), stored in `SE_<shop>.ShopData.service_email` | **From** on customer-facing mail (`mail-kund.txt` order confirmation, welcome, password reset, order status, product watch) **and** From on `mail-order-return-new.txt` and `mail-new-comment.txt`; **To** on the shop's own notifications (`mail-order.txt` copy, `mail-product-watch-admin.txt`, returns, comments). Its domain is what `mailgunSyncDomains.sh` registers in Mailgun. |
| **Platform address** `System::email_support` in `/etc/shopexpo.conf` | Ansible `neh_install_my_email`, default `noreply@shop.nordiskehandel.com` (`roles/neh-install/defaults/main.yml:266`); per-host override in `inventory-nehcloud/host_vars/` (securitas: `order@webshop.securitas.se`) | **From** on `mail-order.txt` (the shop's order copy, shown as `Internetbutiken <…>`, `Reply-To: <customer>`) and `mail-product-watch-admin.txt` only. A sender, never a recipient. |
| Applicant's address | — | **From** on `mail-reseller-request.txt` (`$Data.email`): its domain is in no sasl map, so it goes out on the fallback credential and DMARC can fail for it. |

So an order produces two mails: the confirmation **to the customer, From the store e-mail**
(Mailgun domain = store e-mail domain), and the copy **to the store e-mail, From the platform
address** (Mailgun domain = platform domain). If only one arrives, start from the domain of the
missing one.

```sh
# on the shop host (sudo mariadb needs no password)
sudo mariadb -N -e "SELECT service_email FROM SE_<shop>.ShopData"
grep '^System::email_support' /etc/shopexpo.conf
```

The headers are the first lines of the template that produced the mail. Resolution
(`SE_sys/code/Util.pm:1110-1168`): plugin hook `RESOLVE_ROOT_TEMPLATE_PRE` first, then the shop's
own copy in `/home/www/SE/<shop>/mail-*.txt`, then `SE_sys/templates/mail-*.txt` (or
`SE_sys/templates/mail/version2/` when the admin's SystemMail entry for that file has
`layout_version=2`), then `plugins/code/_commonLib/templates/shop_root/`. A `<name>.<language>`
variant is tried before the plain name at each step. A shop with its own template copy keeps that
copy's headers.

## Which Mailgun domain did the mail go through?

Postfix picks the SMTP credential from the **envelope sender domain**
(`smtp_sender_dependent_authentication = yes`, `roles/postfix/templates/main.cf.j2`):

0. `sender_dependent_relayhost_maps` (`/etc/postfix/relayhost_map`) — some sender domains never
   reach Mailgun at all (securitas: `@securitas.se`, `@webshop.securitas.se` →
   `altmgw10.alt.securitas.se:587`, from its host_vars). Check this first on hosts with host_vars.
1. `/etc/postfix/sasl_passwd_autogenerated` — one line per shop sender domain, written by
   `/usr/local/bin/mailgunSyncDomains.sh` (`roles/neh-install/files/`). Keyed on the domain of
   `ShopData.service_email` per `SE_*` database (`ltgdisplay` is forced to `shop.ltg.se`). A line is
   added only if the domain passes the script's DKIM TXT and SPF checks **and** Mailgun reports it
   `active`.
2. `/etc/postfix/sasl_passwd` — platform domains (`@shop.nordiskehandel.com`,
   `@nordiskehandel.com`, `@rootmail*.nordiskehandel.com`, per-host extras from vault/host_vars).
3. Fallback `[smtp.eu.mailgun.org]:2525` — used when the sender domain matches nothing. The
   credential is `reg_mailgun_smtp_login` = `neh@mg.<host fqdn>` (role `mailgun`, password in
   `/etc/postfix/mailgun_default_server_smtp_password`), so the mail goes out through the host's
   `mg.` Mailgun domain with that domain's DKIM, and DMARC fails for the real sender domain.

```sh
sudo sed 's/:[^:]*$/:.../' /etc/postfix/sasl_passwd_autogenerated   # passwords hidden
sudo journalctl --since "16:40" --no-pager | grep 'postfix/'          # queue id, from, to, 250
```

The postfix `cleanup` line gives the Message-ID (`<queue-id@host>`); search Mailgun for it.

## Query recipes (verified 2026-10-12)

```sh
K=$(tr -d '[:space:]' < ~/.tokens/mailgun); B=https://api.eu.mailgun.net; D=example.com

# list domains in the account (paged, limit max 1000)
curl -s --user "api:$K" "$B/v4/domains?limit=100" \
  | jq -r '.total_count as $t | "total=\($t)", (.items[] | [.name, .state, .type] | @tsv)'

# one domain: state must be "active" for mailgunSyncDomains.sh to hand it to postfix
curl -s --user "api:$K" "$B/v3/domains/$D" | jq '.domain | {state, smtp_login, is_disabled, created_at}'

# delivery events, newest first (accepted / delivered / failed / rejected / complained)
curl -s --user "api:$K" "$B/v3/$D/events?limit=25" \
  | jq -r '.items[] | [(.timestamp|todate), .event, .recipient,
      (.message.headers["message-id"] // ""),
      (.["delivery-status"].code // "" | tostring),
      (.["delivery-status"].description // .["delivery-status"].message // .reason // "" | .[0:160])] | @tsv'

# filter by recipient, event type, or time window (RFC 2822 or unix seconds; begin/end)
curl -s --user "api:$K" "$B/v3/$D/events?limit=25&recipient=someone%40example.net"
curl -s --user "api:$K" "$B/v3/$D/events?limit=25&event=failed"
curl -s --user "api:$K" "$B/v3/$D/events?limit=25&begin=1760277600&end=1760281200&ascending=yes"

# suppression lists for the domain
curl -s --user "api:$K" "$B/v3/$D/bounces"      | jq -c '.items[] | {address, code, error, created_at}'
curl -s --user "api:$K" "$B/v3/$D/complaints"   | jq -c '.items[]'
curl -s --user "api:$K" "$B/v3/$D/unsubscribes" | jq -c '.items[]'
```

Events are kept for a limited time (days, plan dependent), so query soon after the send. A
`failed` event carries the remote server's reply in `delivery-status.message`; a Google
`550 5.1.1 … does not exist` means the recipient mailbox is wrong, not the sender.

## Reading the result

| Mailgun shows | Meaning | Where to look next |
|---|---|---|
| no event for the Message-ID on domain D | postfix used another credential or relay | the relayhost map and sasl maps above, then the host's `mg.` fallback domain |
| `accepted` then `delivered` | Mailgun is done | recipient spam folder / Google Workspace quarantine (same-domain sender and recipient is often filtered) |
| `accepted` then `failed`, code 550 | remote server rejected | the message text: no such user, DMARC or spam policy, blocklist |
| `failed` with "Not delivering to previously bounced address" | recipient is on the domain's bounce list | user removes it (below) or uses another address |
| `rejected` | Mailgun refused before sending | domain not active, sandbox, or recipient not authorised |
| domain `state` ≠ `active` | DKIM/SPF not verified | shop DNS (`SE_sys/code/Misc.pm:323-371`): `starweb._domainkey.<domain>` CNAME → `dkim.nordicshops.com`, SPF `include:spf-for-shops.nordicshops.com`, a `_dmarc` record with `p=none|quarantine|reject`; then the **user** reruns `mailgunSyncDomains.sh` on the host |

## Bounce suppression

A hard bounce puts the address on the domain's bounce list and every later send to it is
suppressed. Removing it is a `DELETE` and therefore not done from here; hand the user the command:

```sh
curl -s --user "api:$K" -X DELETE "$B/v3/$D/bounces/someone%40example.net"
```
