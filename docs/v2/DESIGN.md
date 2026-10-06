# V2 design: a WhatsApp order channel that does not trust its platform

V1 (tag `v1`) showed that WhatsApp's Cloud API is at-least-once, can report "200 OK"
for messages that never arrive, and sends delivery truth only through status webhooks,
which V1 discarded. V2 makes every claim checkable: every delivery is stored, every
logical event is applied exactly once, every outbound message's real fate is tracked,
and every failure is visible and recoverable by an operator.

This document is the implementation contract. If code and this document disagree,
fix one of them in the same change.

## 1. Flow and boundaries

```
Meta ─POST─► Webhooks::WhatsappController      (sync, no Meta calls)
               verify HMAC over raw body  → 401 (nothing stored)
               BEGIN
                 INSERT webhook_deliveries (raw body)
                 enqueue ProcessWebhookDeliveryJob   (Solid Queue, same DB → atomic)
               COMMIT                              → 500 if anything here fails
               200
ProcessWebhookDeliveryJob(delivery)                (async)
  claim delivery → processing (conditional UPDATE)
  for each item in entry[].changes[].value.{messages,statuses}:  one transaction per item
    message → Webhooks::MessageHandler   status → Webhooks::StatusHandler
  write outcome; delivery → processed | partially_failed | failed
SendMessageJob(message)                            (async)
  claim pending|retry_scheduled → sending (own committed transaction)
  24h window guard → blocked
  POST /messages (outside any transaction), biz_opaque_callback_data = message id
  record: accepted | retry_scheduled | failed | unknown (own transaction)
Status webhooks come back through the same ingestion path and move the lifecycle forward.
Recurring: StallSweeperJob (stuck processing → failed; stuck sending → unknown).
Operator UI only writes rows and enqueues jobs. It never calls Meta inline.
```

No transaction ever spans an HTTP call. `ApplicationJob.enqueue_after_transaction_commit
= false` and Solid Queue lives in the primary database, so an enqueue inside a
transaction is atomic with it.

## 2. Schema

### `webhook_deliveries` (new): one row per authenticated POST

| column | type | notes |
|---|---|---|
| raw_body | text, null: false | the body received; for bodies Postgres text cannot hold (invalid UTF-8, NUL) a scrubbed display copy |
| raw_body_base64 | text | exact bytes, base64, only for those bodies; `raw_bytes` is what signature checks and replay use |
| body_sha256 | string(64), null: false | indexed, NOT unique: exact redeliveries are kept and counted |
| signature_header | string | |
| request_id | string | Rails request id |
| object_type | string | payload `object` |
| phone_number_id | string | first `value.metadata.phone_number_id` |
| item_counts | jsonb, default {} | `{"messages":n,"statuses":n,"other":n}` |
| status | integer, null: false, default 0 | enum, see §3 |
| attempts | integer, null: false, default 0 | |
| outcome | jsonb, null: false, default {} | `{"items":[{kind,ref,result,detail}], "summary":{result=>count}}` |
| last_error_class, last_error_message | string, text | |
| received_at | datetime, null: false | |
| last_attempted_at, processed_at | datetime | |
| replay_count | integer, null: false, default 0 | |
| last_replayed_at, last_replayed_by | datetime, string | |
| purged_at | datetime | set by `ops:purge` (§13); raw_body is then '' and raw_body_base64 NULL, outcome refs are hashed, and the delivery can no longer be replayed |

Indexes: `[status, received_at]`, `body_sha256`, `received_at`.

### `messages` (extended): inbound and outbound share one table (one timeline)

Add: `status` (integer, null: false, default 0), `purpose` (string),
`idempotency_key` (string), `order_id` (FK, nullable), `webhook_delivery_id` (FK,
nullable), `wa_timestamp` (datetime), `attempts` (integer, default 0),
`next_attempt_at`, `accepted_at`, `sent_at`, `delivered_at`, `read_at`, `failed_at`,
`blocked_at`, `unknown_at` (datetime), `error_code` (integer), `error_category` (string),
`error_title` (string), `error_details` (text), `guard_override_by` (string). `unknown_at` is stamped whenever a message enters `unknown`; `Ops::Report` uses it for `unknown_resolved` (now sent/delivered/read, or a lifecycle timestamp after `unknown_at`) and `unknown_unresolved`.

Indexes: UNIQUE `wa_message_id` WHERE NOT NULL; UNIQUE `idempotency_key` WHERE NOT
NULL; `[direction, status, accepted_at]`; `order_id`; `webhook_delivery_id`.
Remove `default_scope` (order explicitly where needed). Backfill: existing outbound
rows → status `unknown` (V1 never recorded outcomes), inbound → `received`.

### `orders` (extended)

Add `source_message_id` (FK → messages, UNIQUE; nullable only for legacy V1 rows),
`review_status` (integer, default 0), `validation_issues` (jsonb, default []),
`decided_at`, `decided_by`, `rejection_reason`. Status enum becomes
`received: 0, accepted: 1, rejected: 2` (V1's `confirmed: 1` maps to `accepted`).
`total_cents` = sum of the prices the customer saw. Remove `default_scope`.

### Others

- `order_items.catalog_price_cents` (integer, nullable): our price when the order arrived.
- `conversations.last_inbound_at` (datetime): Meta timestamp of the latest customer message.
- `customers.wa_user_id` (string, nullable): business-scoped user id seen in real payloads.
- `products.catalog_synced_digest` (string), `catalog_synced_at`, `catalog_sync_error` (text).
- `catalog_sync_runs` (new): kind, status, batch_handle, requested_items jsonb,
  result jsonb, triggered_by, started_at, finished_at, error_message.

Money is integer cents (bigint for order totals and line prices, so price x quantity cannot overflow). Meta prices are parsed with `BigDecimal(value.to_s)`, never `to_f`.

## 3. State machines

No gem. Each model: an integer enum, an `ALLOWED_TRANSITIONS` hash, and
`transition!(to, **attrs)` which runs
`UPDATE ... SET status = to, ... WHERE id = ? AND status IN (allowed_from)` and returns
true/false. A false return means another worker won; callers treat it as a no-op.
Specs enumerate the full from × to matrix.

**WebhookDelivery:** `received 0, processing 1, processed 2, partially_failed 3,
failed 4, ignored 5, unparseable 6`.
received|failed|partially_failed|processed → processing; processing → processed |
partially_failed | failed | ignored. unparseable and ignored are terminal. processed →
processing only via operator replay. StallSweeper: processing older than 10 minutes →
failed (error "stalled"); while attempts < 3 the sweeper also re-enqueues it. The sweeper re-enqueues
deliveries stuck in `received` for 5 minutes and outbound messages stuck in `pending` for 10
(job claims make duplicate jobs harmless).

**Message (outbound):** `pending 10, sending 20, retry_scheduled 25, accepted 30,
sent 40, delivered 50, read 60, failed 90, blocked 91, unknown 92`; inbound rows are
`received 0`.

| from | to |
|---|---|
| pending | sending, blocked |
| sending | accepted, retry_scheduled, failed, unknown, blocked |
| retry_scheduled | sending (only while Meta has reported nothing: no wa_message_id, no sent/delivered/read timestamp), blocked, sent, delivered, read, failed (the latter four only from a status webhook) |
| accepted | sent, delivered, read, failed |
| sent | delivered, read, failed |
| delivered | read |
| unknown | sent, delivered, read, failed |
| failed | pending (operator resend; only categories auth_config, account_config, transient_exhausted, unclassified) |
| blocked | pending (operator requeue; only while the window is open) |

Status webhooks only move forward by rank accepted 1 < sent 2 < delivered 3 < read 4.
Each lifecycle timestamp is written at most once (`WHERE delivered_at IS NULL`), even
when the status cannot advance (a late `delivered` after `read` still fills
`delivered_at`). `failed` arriving after delivered/read does not change state; it is
recorded as an `anomaly` item outcome. Never resend automatically from sending,
unknown, accepted or later. Statuses that arrive while a message is still `sending`
only stamp their timestamp; whenever the message then moves to `accepted` or
`unknown` (including via the stall sweeper) its state catches up to the furthest
stamped step, so proof of delivery is never stranded behind `unknown`.

A `retry_scheduled` message can be advanced by a status webhook too: when the POST got a
5xx or 131000 but Meta did process it, a `sent`/`delivered`/`read` status (found by our
opaque id, which also stores the `wa_message_id`) moves the row straight to that step and
clears the retry bookkeeping. The retry's claim refuses a message with a `wa_message_id`
or a sent/delivered/read timestamp (logged `send.claim_refused_already_processed`) and
applies the same catch-up instead, so the customer never receives the message twice.

Operator actions (backend only, they write rows and enqueue jobs): `Order#accept!/reject!`
(reason required; queue the `order:<id>:accepted|rejected` notification in the same
transaction; the rejection text is generic and does not repeat the internal reason),
`Message#resend!` (failed, resendable categories), `#requeue!` (blocked, window open now),
`.resend_failed!(category:)`, and `#override_window_send!` (admin experiment: sets
`guard_override_by`, the job then sends despite a closed window and logs
`window.override_send`). A resend/requeue restarts the attempt: attempts back to 0 and the
previous error and lifecycle timestamps cleared.

**Undelivered** is a query, not a state: outbound, status in (accepted, sent),
`accepted_at < 10.minutes.ago`, `delivered_at IS NULL`.

**Order:** `received → accepted | rejected` (terminal). `review_status`
(`clear 0, needs_review 1`) is an independent flag.

## 4. Idempotency keys

| layer | key | mechanism |
|---|---|---|
| HTTP delivery | none (always stored); `body_sha256` counts exact repeats | — |
| inbound message | `messages.wa_message_id` | `INSERT ... ON CONFLICT DO NOTHING RETURNING id` inside the item transaction; no row → `duplicate`, skip ALL side effects |
| order | `orders.source_message_id` UNIQUE | created in the same transaction as its message |
| identical cart sent twice | — | two messages = two orders (V1 log has this). Not deduplicated. |
| status | lifecycle timestamp column | conditional UPDATE; 0 rows → `duplicate` |
| outbound decision | `messages.idempotency_key` | `reply:<inbound message id>`, `greeting:<inbound message id>`, `order:<order id>:received`, `order:<order id>:accepted`, `order:<order id>:rejected`; `ON CONFLICT DO NOTHING`; enqueue only for new rows |
| send execution | status claim pending/retry_scheduled → sending | one worker wins |
| Meta request | Meta's message id (primary); `biz_opaque_callback_data = messages.id` (secondary, best effort) | the Cloud API has no send idempotency key; ambiguous sends become `unknown` and are never resent. They resolve only if Meta echoes our id on a status, which is documented for free-form messages but not for `failed` or explicitly for `catalog_message`; otherwise they stay visibly `unknown` |
| replay / job retry | all of the above | replay re-runs the stored raw body through the same code |

`<inbound message id>` is our `messages.id`, not Meta's id (Meta ids embed phone numbers).

## 5. Webhook HTTP contract

| situation | response | stored |
|---|---|---|
| GET, mode=subscribe, verify token matches (constant-time) | 200, challenge as text | — |
| GET, mismatch or verify token unset | 403 | — |
| POST, signature missing/invalid | 401 | no (log + count only) |
| POST, valid, body not JSON | 200 | yes, `unparseable` |
| POST, valid, `object` ≠ whatsapp_business_account, or phone_number_id ≠ ours | 200 | yes, `ignored` (reason in outcome) |
| POST, valid, stored and enqueued | 200 | yes, `received` |
| POST, DB/enqueue failure | 500 (Meta retries) | no |

HTTP status tells Meta whether to retry. The Health page tells the operator what
failed. Processing failures are never in the HTTP response and never silent.

Signature: HMAC-SHA256 of `request.raw_post` with the app secret,
`ActiveSupport::SecurityUtils.secure_compare`. Fail closed: skipping is allowed only
when `WHATSAPP_ALLOW_UNSIGNED=1` in development/test. Production refuses to boot
without the app secret, verify token, access token, phone number id and admin
credentials. The webhook controller inherits `ActionController::Base` without
`allow_browser`, ParamsWrapper or CSRF, never reads `params`, and logs no payload.

## 6. Processing items

Per message item (one transaction):
1. Insert the inbound message (dedupe on `wa_message_id`).
2. Upsert customer and conversation. Identity: the business-scoped user id
   (`contacts[].user_id` / `messages[].from_user_id`) when present, else the phone
   number (`from`). Either may be missing (Meta omits the phone number for some
   username users since 2026); a message with neither fails as an item.
   `last_inbound_at = GREATEST(last_inbound_at, wa_timestamp)`.
3. `order` → build Order + OrderItems + validation issues (§9), then the outbound
   `order:<id>:received` message. `text` greeting → `greeting:<msg id>` catalog card;
   other text → `reply:<msg id>` fallback. Other types → recorded, no reply.
4. Enqueue SendMessageJob for each newly inserted outbound row.

Per status item (one transaction): find by `wa_message_id`, else by
`biz_opaque_callback_data` (our message id). The opaque id names the message, not the
attempt, so it is trusted only while the message has no `wa_message_id` (and is not
`pending`, i.e. an attempt is or was in flight): then the `wa_message_id` is stored on
first match. A message that already holds a different id has been resent since, so the
status is an `orphan` ("stale id after resend") and changes nothing. Apply forward-only (§3). `errors[]` on `failed` → classify (§7).
No match → `orphan` item outcome (replay applies it later if the message appears).

Item failures roll back that item only; the delivery becomes `partially_failed` (or
`failed` if nothing applied). Infrastructure errors (connection/deadlock) are retried
by the job (3 attempts, polynomial backoff); code/data errors are not: the delivery is
marked failed and is replayable after a fix.

## 7. Outbound sends and error taxonomy

Faraday: open timeout 3 s, read timeout 10 s. Classification applies equally to a
sync error response and to `statuses[].errors[]` on a `failed` webhook.

Classify by Meta `code` first; HTTP status is only a fallback when there is no code.

| category | codes | retry | notes |
|---|---|---|---|
| request_invalid | 100, 131008, 131009✓, 131021, 131051, 131053, 135000 | no | bug or bad data |
| recipient_not_allowed | 131030✓ | no | test-number allow-list (no longer on Meta's page, but received in V1) |
| recipient_undeliverable | 131026, 131049, 131050, 130472 | no | 131049: wait 24h+ before any resend |
| window_closed | 131047 | no | template only (Gate C) |
| auth_config | 0, 190, 10, 200–299, 131005, HTTP 401/403 without a code | no; operator resend after fix | banner |
| account_config | 133010✓, 133000, 131042, 131045 | no; operator resend after fix | banner; 131042 is billing |
| account_quality | 131048, 368, 131031, 131064 | no | stop scenario runs |
| rate_limited | 4, 80007, 130429, 131056, HTTP 429 | yes, long backoff | no Retry-After header exists; 131056 waits 4^attempt seconds |
| transient_platform | 1, 2, 131000, 131016, 131057, 133004, 2494100, HTTP 5xx | yes | |
| transient_network | could not connect (open timeout, refused, DNS), or a TLS handshake/verification failure (`certificate verify failed`, `wrong version number`, `handshake failure`, `no protocols available`) | yes | request never left |
| ambiguous | read timeout, connection reset after the request was sent, any other SSL error (e.g. `SSL_read: unexpected eof`: Faraday raises SSLError for failures while reading the response too) | **no** → `unknown` | resolved only by a correlated status webhook |
| unclassified | anything else | no | flagged as a taxonomy gap |

✓ = received by V1 (real evidence). Everything else comes from Meta's documentation
(`docs/v2/meta-research.md`).

Retry schedule (attempt n waits): 30 s, 2 min, 10 min, 30 min, then
`failed(transient_exhausted)`; rate_limited uses at least 2 min, and 131056 waits
`4**n` seconds (capped at 30 min, still floored at 2 min). A retry never sends
outside the window: the guard turns it into `blocked`.

Recipient: `to` = phone number when known, else `recipient` = business-scoped user id
(supported since July 2026). Graph API version defaults to v26.0 (V1's v21.0 expires
2027-01-21).

## 8. 24-hour window

`open = now < last_inbound_at + 24h - 5min`. Checked in SendMessageJob right before
the HTTP call. Closed → `blocked` (`error_category: window_closed`, `blocked_at`),
Meta is not called. Meta disagreeing (131047 while we thought open, whether in the
HTTP response or in a later `failed` status) → `failed(window_closed)` plus a
`window_disagreement` event. Template fallback only if Gate C passes.

## 9. Order validation

Orders are always recorded. Issues set `review_status: needs_review`.

| case | behavior | issue code |
|---|---|---|
| unknown SKU | line kept, product nil | unknown_sku |
| price ≠ our price | line priced at what the customer saw; `catalog_price_cents` stored | price_mismatch |
| product out of stock locally | flagged | unavailable |
| quantity not an integer ≥ 1 | line dropped | invalid_quantity |
| currency ≠ product currency | flagged | currency_mismatch |
| catalog_id ≠ configured CATALOG_ID (when configured) | flagged | unknown_catalog |
| no usable lines | order kept, empty | malformed |
| `order` object missing | item fails (replayable) | — |

Issue shape: `{code, sku, expected, actual}`. Rules chosen: honor the customer's
price, never auto-reject, no quantity caps. The automatic receipt is neutral; the
acceptance message states the final total.

## 10. Replay and resend

Replay (operator, POST + CSRF, Basic auth): only deliveries in failed,
partially_failed, processed whose body has not been purged. Re-verifies the stored signature against the stored body
first. Re-runs the full raw body through ProcessWebhookDeliveryJob; idempotency makes
applied items no-ops. Records replay_count, last_replayed_at, last_replayed_by and a
`webhook.replayed` log event. Resend acts on a message row (§3 rules).

## 11. Logging and PII

Structured key=value/JSON logs with request_id, delivery_id, message_id (ours),
order_id, job_id, error_category. Never log Meta message ids (they embed phone
numbers), phone numbers (mask to last 4), names, or payload bodies.
`DEMO_MASK_PII=1` masks phone numbers and names in every admin view.

## 12. Fault injection (operating-period scenarios 4, 6, 7)

`FaultInjection` reads `FAULT_INJECT` (comma-separated) on every check:

| toggle | effect |
|---|---|
| `processing:order` | `MessageHandler` raises `FaultInjection::Injected` for order items: the item rolls back, the delivery becomes failed/partially_failed and is replayable once the toggle is removed. The item detail reads `FaultInjection::Injected: injected:processing:order`. |
| `send:5xx` | `WhatsappClient` returns a synthetic 503 (`transient_platform`, retryable) without calling Meta. The message's `error_details` starts with `[injected]`. |
| `send:read_timeout_after_send` | the real request is made, the response is discarded and the ambiguous result returned, so the message becomes `unknown`. `error_details` starts with `[injected]`. |

Only honoured when `Rails.env.local?`, or in production with `FAULT_INJECTION_ALLOWED=1`;
production refuses to boot with `FAULT_INJECT` set but not allowed. A toggle fires for
every matching event while set; every firing logs `fault.injected` (warn) with the kind.
The Health page shows a red banner listing the active toggles.

## 13. Purge after the operating period

`bin/rails ops:purge BEFORE=YYYY-MM-DD CONFIRM=yes [FORCE=yes]` (`Ops::Purge`; the old name
`ops:purge_payloads` is an alias) keeps the consent promise ("phone number and name are stored
until the purge date") and keeps every aggregate. For records created (received, for
deliveries) before the date:

| table | removed | marker |
|---|---|---|
| `webhook_deliveries` | `raw_body = ''`, `raw_body_base64 = NULL`, Meta ids in `outcome.items[].ref` replaced by `purged:<12 hex of sha256>` | `purged_at` |
| `messages` | `body`, `raw_payload = {}`, `wa_message_id`, `error_details` set to NULL / empty | `purged_at` |
| `orders` | `wa_order_note` NULL | |
| `customers` whose last activity (creation, last message either way, last order) is before the date | `display_name` NULL, `whatsapp_number` NULL, `wa_user_id = 'purged:<id>'` (the identity check constraint needs one) | `purged_at`, `purged_had_phone` |

Kept: statuses, timestamps, attempt counts, error code/category/title, body hashes, item
results and the other aggregates. `ops:report` gives the same counts before and after
(`customers_without_phone` reads `purged_had_phone` for purged customers).

Skipped and reported, never silently lost (unless `FORCE=yes`): deliveries in
`received`/`processing`/`failed`/`partially_failed` (unapplied items; the body is what a replay
needs), outbound messages in `pending`/`sending`/`retry_scheduled` (the request about to be
sent), `failed` (resendable) and `unknown` (waiting for a status that names its
`wa_message_id`), and customers who have such a message. Without `CONFIRM=yes` the task refuses
and prints the counts per table; BEFORE may not be in the future. Counts per table are printed.
The purge is idempotent.

After a purge: a purged delivery refuses replay ("the raw body was purged on <date>") and the
admin UI hides its Replay button; `Message#resend!`/`#requeue!`/`#override_window_send!` refuse
a purged message with the reason `purged`; `Order#accept!`/`#reject!` refuse an order whose
customer was purged (there is no one to notify); a returning person is simply a new customer.

## 14. Demo simulator (local screenshots and video only)

`bin/rails demo:simulate` (`Demo::Simulator`) plays a fixed, seeded script through the real
webhook controller and jobs so the admin UI can be populated for screenshots. It runs only in
development, never in production, and only against a database whose name contains `_demo`
(`DATABASE_URL=postgres:///whatsapp_integration_demo bin/rails db:prepare db:seed demo:simulate`).
`WhatsappClient` is pointed at an in-process Faraday adapter, so no request can leave the
process whatever token is configured; statuses arrive as correctly signed POSTs (demo app
secret); jobs run in the foreground. Simulated records are identifiable: customers are
"Demo Customer N" with fake numbers, every log event of the run carries `simulated=true`,
webhook bodies carry `"simulated":true` and Meta ids start with `wamid.DEMO`.
