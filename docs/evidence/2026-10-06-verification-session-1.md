# Verification session 1 — 2026-10-06

**Label: real.** Live WhatsApp traffic between one customer phone (the author's) and the
deployed app at https://whatsapp.railsfanatics.com, through Meta's Cloud API. This is a
verification session, not an operating period (none was run; [criteria](../operating/PROTOCOL.md)).
Everything below is read from the production database and logs; ids are the app's own.
Phone numbers, names and Meta message ids are left out on purpose. All times UTC.

## Setup the account owner did by hand (Meta)

1. **Webhook.** In the use-case app flow the setting lives under *Use cases > Customize >
   Configuration*, not under *WhatsApp > Configuration*. Meta's verification request reached
   the server and was answered 200.
2. **Number registration.** The new business number was *verified* (voice call) but not
   *registered*: the read-only check showed `platform_type=NOT_APPLICABLE status=PENDING`,
   and a customer opening a chat was told the number is not on WhatsApp. One
   `POST /{phone-number-id}/register` later it showed `CLOUD_API CONNECTED`.
3. **Commerce settings.** See the failure below.

## What happened

| Time | Event | Result |
|---|---|---|
| 16:14:17 | Customer sends "Hi" (delivery #42) | Signature valid; stored, processed, applied once |
| 16:14 | App sends the catalog card (message #30) | **Failed synchronously: 131009** (see below). Classified, not retried |
| 16:17:14 | Customer sends "Hi" again (delivery #43) | Applied once |
| 16:17:17 | Catalog card (message #32) | Accepted by Meta; `sent` 16:17:17; `read` 16:17:18 |
| 16:19:36 | Customer sends a cart (delivery #46) | **Order #9**: 2 lines, $24.50; both prices equal the catalog price; review clear; catalog id matches |
| 16:19:37 | Order receipt (message #34) | Accepted; `sent` 16:19:38; `read` 16:19:38 |
| 16:20:44 | Operator accepts order #9 in the admin | |
| 16:20:46 | Acceptance notice (message #35) | Accepted; `sent` 16:20:46; `delivered` 16:20:47; `read` 16:20:54 |

Totals: 10 real webhook deliveries (3 messages, 7 statuses), all `processed`; 0 duplicates,
0 orphans, 0 anomalies, 0 failed jobs; every send needed one attempt; nothing left in
flight.

## The failure, accurately

The first catalog card was rejected with **131009 "Parameter value is not valid"**, details:
*"Check if a catalog is linked to the WhatsApp Business Account and the catalog is enabled in
the WhatsApp Commerce Settings."* The catalog *was* linked to the business account (the
read-only check confirmed it). The missing piece was per number: this newly registered number
had the catalog switched off in its commerce settings. The owner enabled the catalog
and cart for the number by hand in Meta's settings; nothing was retried automatically, and
the next "Hi" got a new, working catalog card.

V1's August log held this same code five times on the webhook path, with three different
`error_data.details`: three times a request bug (a `catalog_message` without
`thumbnail_product_retailer_id`), once exactly this Commerce Settings cause, and once
"Products not found in FB Catalog". V1 kept them only in a log line, so nobody could tell
them apart. V2 stored the code and the details on the message, which made the diagnosis
here immediate. Only `error_data.details` separates the causes. At the time V2 classified
the failure as `request_invalid` (not resendable), which was wrong for the configuration
case. Fixed the same day: a 131009 whose details name
the commerce settings is now `account_config`, which an operator can resend after fixing
it. Message #30 keeps its original classification as the historical record.

## Observed platform behaviour

- **`delivered` is skipped when a message is read immediately.** Seen twice (messages #32
  and #34: `sent` then `read`). Message #35, read eight seconds later, went through
  `delivered`. The app only moves statuses forward and fills each timestamp once, so both
  orderings produced the right final state.
- **The correlation id is echoed.** All 7 status webhooks carried
  `biz_opaque_callback_data` equal to the app's own message id, for an interactive
  `catalog_message` and for text messages, on `sent`, `delivered` and `read`. Echo on a
  `failed` status was not observed (the only failure was synchronous).
- **Status webhooks carry business-scoped user ids and per-message pricing.**
- **Catalog read-back price format** is a display string, e.g. `"$5.00"`.

## Deployment checks on the live host, the same day

Run against https://whatsapp.railsfanatics.com before and around the session (by the
operator, not by Meta):

- HTTPS with a Let's Encrypt certificate; `/up` 200; HTTP redirected to HTTPS.
- Webhook endpoint: wrong verify token 403; POST without a signature 401; POST with a
  forged signature 401; a 4 MB body 413 (refused before Rails); `/webhooks/whatsapp.json` 404.
- Admin without or with wrong credentials 401; with the operator's credentials every
  admin page 200.
- Background jobs: a harmless job processed; a deliberately unloadable job recorded as a
  failed execution and then discarded; after a container restart the app was healthy again
  in about 6 seconds with jobs processing and data intact.
- Backups: one `pg_dump` taken; a non-destructive restore drill into a scratch database
  matched production row counts and schema version; the scratch database was dropped.
  The nightly cron dump was installed and first ran on schedule on 2026-10-07 (after this
  session). The off-host copy in the runbook has not been performed, and there is no
  heartbeat or uptime monitor yet.

## Found and fixed afterwards

- 131009 classification (above).
- Meta's verification request carries the verify token in its query string. Rails' log
  filtered it, but the web server's own access log (Thruster) recorded it; that log is now
  off. The shared reverse proxy's access log has no redaction option and kept that one line.
- The read-only setup check masked numbers badly when they contained spaces; fixed.

## Still unverified after this session

Catalog API push (`items_batch`) and reconcile against Meta; correlation-id echo on `failed`;
a real duplicate delivery handled by V2; the 24h window block and override against Meta;
real orders with price mismatch, unknown SKU, unavailable product or invalid quantity; real
retryable and ambiguous send failures. They are covered by specs and the synthetic seed
(simulated only). They were scenarios in the planned operating period, which was
intentionally not pursued (decision 2026-10-07; see [the protocol](../operating/PROTOCOL.md)).
