# The Local Table: WhatsApp Catalog + Cart order channel (V2)

A Rails 8.1 application that receives orders placed through WhatsApp's native
Catalog and Cart, records them, lets an operator accept or reject them, and
tells the customer. "The Local Table" is a fictional restaurant; the menu is
seed data.

V2 is a production-oriented reference implementation. Its premise is that a
reliable integration has to be built on a platform whose responses cannot be
taken at face value: webhooks arrive at least once and unordered, a `200 OK`
from the send API does not mean a message arrived, and delivery truth comes
only from later status webhooks. V2 therefore stores every delivery before
interpreting it, applies every logical event exactly once, tracks the real fate
of every outbound message, and makes failures visible and recoverable.

It is deployed as an integration environment at
https://whatsapp.railsfanatics.com and has completed one real end-to-end
verification session against Meta (2026-10-06, the author as the only
customer; see [the session write-up](docs/evidence/2026-10-06-verification-session-1.md)).
It has no real customers, and the controlled operating period has not started
(see Status). The original demo is preserved at tag `v1`. The lessons behind
the design are written up in the
[field guide article](https://amitsolanki.com/writing/whatsapp-catalog-cart-field-guide/).

## Status

Evidence is labelled by kind. **Real (V1)** is traffic from V1's live run on
2026-08-08. **Real (V2)** is verification session 1 on 2026-10-06: one
participant (the author), live Meta traffic to the deployed app.
**Simulated** is signed fixtures and stubbed HTTP inside the specs.
**Unverified** has not been exercised against Meta.

| Area | State | Evidence |
|---|---|---|
| Webhook intake: signature check, store-first, atomic enqueue, size guard | Deployed | Real (V2): 10 signed deliveries stored and processed exactly once; forged, unsigned and oversized requests rejected on the live host. Specs |
| Per-item idempotent processing, replay | Deployed | Simulated, using fixtures sanitized from real V1 payloads. No duplicate delivery occurred in session 1 |
| Duplicate delivery handling | Deployed | Real input from V1 (Meta delivered the same `delivered` status twice); V2 handling is a spec |
| Outbound lifecycle and status webhooks | Deployed | Real (V2): catalog card, order receipt and acceptance notice tracked through Meta's status webhooks to `read`, including statuses arriving with `delivered` skipped |
| Correlation id echo (`biz_opaque_callback_data`) | Deployed | Real (V2): echoed on all 7 `sent`/`delivered`/`read` webhooks, for `catalog_message` and text. **Unverified on `failed`** |
| Error taxonomy | Deployed | Real: 131009 (V1 and V2), 131030, 133010 (V1). Other codes come from Meta's documentation |
| 24h guard, operator actions | Deployed | Real (V2): an operator acceptance reached the customer. Window blocking and override: simulated only |
| Order validation | Deployed | Real (V2): one clean order (prices matched the catalog). Mismatch, unknown SKU, unavailable, quantity: simulated only |
| Operator UI, PII masking, fail-closed auth | Deployed | Real (V2): used to accept order #9; auth refusal checked on the live host. Specs |
| Catalog push, batch polling, reconcile | Implemented, **off** | Catalog read access verified live (read-back price format `"$5.00"`). **Push (`items_batch`) not verified against Meta** |
| Fault injection, demo simulator, synthetic seed, payload purge | Deployed | Simulated (specs, and the seed on the live host). Injected and synthetic rows are labelled permanently and excluded from real metrics |
| Deployment, backups | Deployed | Kamal on a shared VPS; one backup taken and a non-destructive restore drill passed (2026-10-06) |
| Operating period | **Not started** | Criteria in [`docs/operating/PROTOCOL.md`](docs/operating/PROTOCOL.md): 14+ days, 2+ participants besides the author, every scenario twice |

Observed on `main` at the time of writing: `bundle exec rspec` reports 1111 examples, 0 failures
(local PostgreSQL, about 17 seconds). Specs verify the code against the
fixtures and stubs described above; they say nothing about how Meta behaves.


## What V1 got wrong

From V1's code (`git show v1:...`), the sanitized fixtures and the design notes:

- **Status webhooks were discarded.** The processor skipped every change
  without `messages`, so `sent`, `delivered`, `read` and `failed` never reached
  the database. Delivery truth was thrown away.
- **Errors behind 200s.** The controller rescued every exception and answered
  `200`, so Meta saw success for work that failed, and nothing was stored to
  retry from. The signature check was skipped whenever no app secret was set.
- **Placeholder outbound records.** After a reply it wrote an outbound row with
  the body `(auto-reply sent)`, recorded without the send outcome, Meta's
  message id or any status. Order confirmations were sent inline from the
  webhook request.
- **Fixture and reality disagreed.** The hand-written order fixture used string
  `quantity` and `item_price` and non-empty text; real orders carry numeric
  values and an empty `text`. Prices went through `to_f`.
- **Duplicates were real.** Meta delivered the same `delivered` status twice, in
  separate POSTs from two hosts within the same second. V1 had no unique
  constraint on `wa_message_id`. (The archived V1 database itself contained no
  duplicated message ids; the duplicate evidence is in the status traffic.)
- **Customers were identified by phone number only.** Real V1 payloads already
  carried a business-scoped user id.

## Architecture

```
Meta --POST--> Webhooks::WhatsappController      (sync, never calls Meta)
                 WebhookGuard (rack): 413 over 3 MB, 401 without a signature header
                 verify HMAC over the raw body       -> 401, nothing stored
                 BEGIN
                   INSERT webhook_deliveries (raw body, sha256)
                   enqueue ProcessWebhookDeliveryJob  (Solid Queue, same DB)
                 COMMIT                              -> 500 if this fails (Meta retries)
                 200
ProcessWebhookDeliveryJob                        (async)
  claim: received|failed -> processing (conditional UPDATE)
  for each entry[].changes[].value.{messages,statuses}: one transaction per item
    message -> MessageHandler: insert inbound (ON CONFLICT DO NOTHING), customer,
               conversation, Orders::Builder, outbox row + SendMessageJob
    status  -> StatusHandler: forward-only lifecycle update
  record per-item outcome; delivery -> processed | partially_failed | failed | ignored
SendMessageJob                                   (async)
  claim pending|retry_scheduled -> sending; 24h window guard -> blocked
  POST /messages (outside any transaction), biz_opaque_callback_data = our message id
  record accepted | retry_scheduled | failed | unknown (own transaction)
Status webhooks re-enter through the same intake and move the lifecycle forward.
Recurring: StallSweeperJob (5 min), CatalogReconcileJob (daily 03:00)
Operator UI: writes rows and enqueues jobs; never calls Meta inline.
```

Boundaries worth knowing:

- No database transaction spans an HTTP call. `ApplicationJob` pins
  `enqueue_after_transaction_commit = false`; a failed enqueue raises
  `ApplicationJob::EnqueueFailed` so the surrounding transaction rolls back.
- `WhatsappClient` and `Catalog::Client` are the only code that talks to Meta.
  Neither raises for API or transport problems; both return classified results.
- `Conversations::Responder` decides what to say and never sends. It is canned
  text and one catalog card; there is no LLM.
- State changes go through `StatusTransitions#transition!`, a single conditional
  `UPDATE ... WHERE status IN (allowed sources)`. The database decides who wins;
  a `false` return is a no-op for the caller.
- One Rails process (Puma with the Solid Queue supervisor inside), one PostgreSQL
  database; no Redis.

The full contract (schema, state tables, HTTP contract, validation rules) is
[docs/v2/DESIGN.md](docs/v2/DESIGN.md).

## Design decisions

**Store first, acknowledge fast.** The controller verifies the signature,
writes the raw body and a job row in one transaction, and returns 200.
Interpretation happens later, so a processing bug never loses a delivery and
never makes Meta redeliver one it already got. Bodies PostgreSQL text cannot
hold (invalid UTF-8, NUL) are stored as a scrubbed display copy plus the exact
bytes in base64, so the signature can still be re-verified on replay. Requests
with a bad signature are not stored (logged and counted only).

**Solid Queue in the primary database.** The delivery row and its job commit
or roll back together, which removes the "stored but never enqueued" window
without an outbox relay. The cost is that queue load shares the application
database, which is acceptable at this scale and would not be at a larger one.

**Idempotency at the item level, not the request level.** Exact redeliveries are
kept and counted (`body_sha256` is indexed, not unique); duplicates are removed
when items are applied:

| Layer | Key | Mechanism |
|---|---|---|
| Inbound message | `messages.wa_message_id` (unique) | `INSERT ... ON CONFLICT DO NOTHING RETURNING id`; no row means `duplicate` and every side effect is skipped |
| Order | `orders.source_message_id` (unique) | created in the same transaction as its message |
| Status | lifecycle timestamp column | conditional UPDATE; zero rows means `duplicate` |
| Outbound decision | `messages.idempotency_key` (unique) | e.g. `reply:<msg id>`, `order:<id>:accepted`; enqueue only for new rows |
| Send execution | status claim | `pending`/`retry_scheduled` to `sending`, one worker wins |
| Replay and job retry | all of the above | re-runs the stored raw body through the same code |

Two identical carts sent separately are two messages and two orders; they are
not deduplicated. The Cloud API has no send idempotency key, so the Meta request
itself is not idempotent (next paragraphs).

**Forward-only status, timestamps written once.** Outbound messages move
`pending, sending, accepted, sent, delivered, read` with `failed`, `blocked`,
`unknown` and `retry_scheduled` as side states. A webhook can only advance by
rank, and each of `accepted_at`, `sent_at`, `delivered_at`, `read_at` is written
at most once, even when the state cannot advance (a late `delivered` after
`read` still fills `delivered_at`). A `failed` after `delivered` or `read`
changes nothing and is recorded as an `anomaly` item. Statuses that arrive while
a send is still `sending` stamp their time only; the state catches up when the
send settles, so proof of delivery is never stranded behind `unknown`. The same
holds for a `retry_scheduled` message (a 5xx that Meta had in fact processed): the status
settles it and the scheduled retry refuses to send a second copy. A status
for an unknown message is stored as an `orphan` item and applied on replay.

**No automatic resend of ambiguous sends.** A read timeout, or a connection
reset after the request was written, may mean Meta has the message. With no
idempotency key, resending could duplicate it, so the message becomes `unknown`
and stays visible. It resolves only if a status webhook arrives, matched by
Meta's message id or by `biz_opaque_callback_data` (our message id, best
effort). The stall sweeper moves sends stuck in `sending` to `unknown` for the
same reason. Operators may resend only `failed` messages in fixable categories.

**Error taxonomy by Meta code, not HTTP status.**
`Whatsapp::ErrorClassifier` maps `code` to a category (HTTP status is a fallback
only when there is no code). The same table serves synchronous errors and
`statuses[].errors[]` on `failed` webhooks.

| Category | Examples | Outcome |
|---|---|---|
| request_invalid, recipient_not_allowed, recipient_undeliverable, window_closed | 100, 131009, 131030, 131026, 131047 | fail, no retry |
| auth_config, account_config | 190, 133010, 131042 | fail; operator resends after fixing; Health banner |
| account_quality | 131048, 131064 | fail, no retry |
| rate_limited | 4, 80007, 130429, 131056 | retry with long backoff |
| transient_platform, transient_network | 1, 2, 131000, HTTP 5xx, connect refused or DNS | retry |
| ambiguous | read timeout, reset after send | `unknown`, never retried |
| unclassified | any other code | fail; flagged as a taxonomy gap |

Retries wait 30 s, 2 min, 10 min, 30 min, then `failed(transient_exhausted)`.
Codes marked as received by V1 in `error_classifier.rb` are real; the others
are from documentation.

**24-hour window guard, with margin.** A free-form send is allowed while
`now < last_inbound_at + 24h - 5min`, checked in `SendMessageJob` immediately
before the HTTP call (retries included). A closed window yields `blocked` and no
call to Meta. If Meta returns 131047 while the guard thought the window was
open, the message fails and a `window_disagreement` event is logged. Meta's
actual behavior here (synchronous error, async `failed`, or silence) is
undocumented.

**Always record orders; flag problems.** The customer already sent the cart and
saw prices, so `Orders::Builder` never rejects. Issues set
`review_status: needs_review` with a structured list: `unknown_sku`,
`price_mismatch`, `unavailable`, `invalid_quantity`, `currency_mismatch`,
`unknown_catalog`, `malformed`. The line is priced at what the customer saw and
our price is kept in `catalog_price_cents`. Prices are parsed with `BigDecimal`,
never `to_f`; money is integer cents. Acceptance states the final total; the
automatic receipt deliberately states none.

**Customer identity by business-scoped user id.** Meta now sends a user id with
every webhook and omits the phone number for some users. A customer is keyed by
user id when present, else phone number; a database check requires at least one.
Identifiers are only filled in, never overwritten, and only from messages that
are new. Sends use `to` when a phone number is known, else `recipient` with the
user id.

**Catalog push plus read-only reconcile, CSV feed as fallback.** With
`CATALOG_SYNC_ENABLED=true`, a product edit enqueues a debounced push of every
dirty product (SHA256 digest of the Meta-visible fields) through `items_batch`;
`CatalogBatchStatusJob` polls until `finished` and marks products synced at the
digest that was sent, so edits made in flight stay dirty. `CatalogReconcileJob`
reads the catalog back daily and records drift; it never corrects anything.
There are no deletes: out of stock is the removal. `preorder` is sent as
`out of stock` because the documentation does not list it. Details and the
live checks still required: [docs/v2/CATALOG.md](docs/v2/CATALOG.md).

**Fail-closed signature and admin auth.** Signature: HMAC-SHA256 over
`request.raw_post`, compared in constant time; no secret means every POST is
refused. `WHATSAPP_ALLOW_UNSIGNED=1` works only where `Rails.env.local?`. Admin:
HTTP Basic; if either credential is unset nobody gets in.
`ADMIN_AUTH_DISABLED=1` works only in development and test. Production refuses
to boot without the Meta token, phone number id, verify token, app secret,
admin credentials and `APP_HOST`, or with `WHATSAPP_ALLOW_UNSIGNED` set.
The webhook controller inherits `ActionController::Base`, skips CSRF, and
suppresses parameter logging, since the parameters are the payload.

**PII rules.** Meta message ids embed phone numbers, so they are never logged
or shown; logs carry our own ids. `AppLog` rejects forbidden fields (bodies,
phone numbers, names, Meta ids) and raises in development and test. Error text
that did not come straight from Meta passes through `Redact`. Statements that
would render PII inline run with SQL logging silenced. The admin deliveries
pages never load `raw_body`. `DEMO_MASK_PII=1` masks phone numbers (last four
digits) and names in every admin view. Raw webhook bodies and message payloads
are stored in the database as received and contain PII.

## Operator UI

All under `/admin`, behind Basic auth. Most pages refresh every 5 seconds (`pause`
link in the footer). Every
write action records the operator's username as `by:` and logs an event. None
calls Meta from the request.

| Page | Shows |
|---|---|
| Health (`/admin`, landing) | Failed and partially failed deliveries with "Replay all failed"; outbound counts by status; failed sends by category with "Resend all failed in <category>" for fixable ones; `unknown` sends; undelivered over 10 minutes; blocked by the window; retry-scheduled; orders needing review; orphan and anomaly counts (7 days); failed background jobs; a banner when recent failures are all configuration (auth or account); catalog sync state (last push and reconcile, unsynced count, drift, failing products) with "Sync now" and "Reconcile now" |
| Orders | Filters: all, needs review, received, accepted, rejected. Detail shows lines with the customer's price beside the catalog price, validation issues, accept, and reject (internal reason required, not sent to the customer), and the order's notification messages. Warns when the window is closed so the notification will be blocked |
| Conversations | List with 24h window state; per-customer timeline of inbound and outbound messages with delivery state, error details, and per-message Resend, Requeue, and "Override window (experiment)", which needs a confirmation box and is meant to learn what Meta does |
| Deliveries | Every stored POST filtered by status, with item outcomes (references masked to six characters), attempts, replay count, last error, body fingerprint; replay for failed, partially failed or processed. Replay re-verifies the stored signature against the stored body first |
| Products | Menu with availability, synced or not, last sync time, sync error |

The public menu (`/`, `/products/:id`) and `GET /catalog/feed.csv` are
unauthenticated by design; `GET /up` is the health check. No screenshots yet.

## Running locally

Requires Ruby 3.4.7 and PostgreSQL.

```bash
bundle install
bin/rails db:prepare db:seed     # schema, then the 20-item menu
bin/dev                          # Puma with the Solid Queue supervisor inside
```

Open `http://localhost:3000/admin`. For local use, either set
`ADMIN_AUTH_DISABLED=1` (development and test only; the operator becomes
`dev-operator`) or set `ADMIN_USER` and `ADMIN_PASSWORD`. To post unsigned
webhooks with curl, set `WHATSAPP_ALLOW_UNSIGNED=1` (same restriction).
`bin/setup` also works but clears logs and tmp files.

Copy `.env.example` to `.env` (loaded by `dotenv-rails` in development and
test):

| Variable | Purpose |
|---|---|
| `WHATSAPP_TOKEN` | System User token for the Graph API |
| `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_BUSINESS_ACCOUNT_ID` | Sending number (Meta's id for it) and account |
| `WHATSAPP_DISPLAY_PHONE_NUMBER` | Optional. The business number's digits; only the setup check uses it, to confirm the phone number id belongs to it. Keep it out of tracked files |
| `WHATSAPP_VERIFY_TOKEN` | Value you choose; must match Meta's webhook config |
| `WHATSAPP_APP_SECRET` | Verifies `X-Hub-Signature-256` |
| `WHATSAPP_ALLOW_UNSIGNED` | `1` skips signature checks; development and test only |
| `ADMIN_USER`, `ADMIN_PASSWORD` | Operator UI credentials; required in production |
| `ADMIN_AUTH_DISABLED` | `1` disables admin auth; development and test only |
| `DEMO_MASK_PII` | `1` masks phone numbers and names in the admin UI |
| `CATALOG_ID`, `CATALOG_SYNC_ENABLED` | Catalog target; `true` turns on push and scheduled reconcile (default off) |
| `WHATSAPP_API_VERSION` | Graph version, default `v26.0` |
| `APP_HOST` | Public host used in catalog item links; required in production |

Tests and CI:
```bash
bundle exec rspec                 # needs PostgreSQL; DATABASE_URL overrides the test database
bin/rubocop
bin/brakeman --no-pager && bin/bundler-audit
```

`.github/workflows/ci.yml` runs three jobs on pull requests and pushes to
`main`: `lint` (RuboCop), `security` (Brakeman, bundler-audit), and `test`
(`rspec` against PostgreSQL 17). `bin/rails ops:report FROM=2026-10-20
TO=2026-11-10 FORMAT=md` prints delivery, order, outbound, latency, status
anomaly, window, catalog and inbound metrics computed only from the database,
twice: `real` (rows with no injected fault, nothing synthetic or simulated: see
`demo:seed_integration` below) and `all`, plus
an `injected` summary by label. `bin/rails ops:repost_delivery ID=… CONFIRM=yes` re-ingests
a stored delivery's exact bytes as a new delivery labeled `injected:repost` (scenario 3), so
it never counts as one of Meta's own duplicates.

Operating tools (`docs/operating/PROTOCOL.md`):

- Fault injection (`processing:order`, `send:5xx`, `send:read_timeout_after_send`) makes
  deliberate, labeled failures for the scenario runs. The toggles are stored in the
  database and switched on the Health page ("Fault injection" panel, shown only when
  allowed; the operator's name is recorded), so no redeploy is needed. Allowed only in
  development/test, or in production with `FAULT_INJECTION_ALLOWED=1` (a deploy-time
  setting, default `"0"` in `config/deploy.yml`). In development and test the
  `FAULT_INJECT` environment variable is an extra source; production refuses to boot with
  it set. A toggle fires for every matching event until switched off. Health shows a
  red banner while any toggle is on.
- `bin/rails demo:simulate` builds a local, clearly simulated dataset for
  screenshots: fake customers ("Demo Customer N", +1 555 010 numbers), signed
  webhooks through the real controller, an in-process fake Graph API. It runs
  only in development and only against a database whose name contains `_demo`:
  `DATABASE_URL=postgres:///whatsapp_integration_demo bin/rails db:prepare db:seed demo:simulate`.
- `bin/rails demo:seed_integration CONFIRM=yes` fills the operator UI with clearly
  **synthetic** traffic so a fresh deployment is not empty. Unlike `demo:simulate` it is safe
  in ANY environment, production included, next to the real token (without `CONFIRM=yes` it
  prints what it would replace and changes nothing). It first removes all earlier synthetic
  data, then plays 12 scenarios (greeting and catalog card, clean order accepted, price
  mismatch, unknown SKU, unavailable product, invalid quantity, permanent send failure,
  ambiguous send, duplicate status, injected failure and replay, rejected order, send blocked
  by the 24h window) through the real webhook controller and jobs, with timestamps spread
  over the last days. Everything it creates is flagged `synthetic` (customers "Demo Customer
  N" with 1 555 010 xxxx numbers, `sim.in.N` / `sim.out.N` message ids, DEMO-* products in the
  category "Demo items (synthetic)") and carries a "synthetic" badge in the admin. It runs
  entirely in-process in one transaction: WhatsApp and catalog calls go to an in-process fake,
  the token, phone number id and signing secret are run-local fakes, Solid Queue is not used,
  fault injection is a process-local override (the stored toggles are neither read nor
  written), and Net::HTTP cannot connect. It rolls everything back, raising, unless the end
  state holds: no outbound message in flight, no Solid Queue job, no network attempt, only
  synthetic customers, deliveries and products. Same counts on every run.
  `bin/rails demo:purge_synthetic CONFIRM=yes` removes exactly that data and nothing else.
  Guards that hold in production for synthetic data at all times: `SendMessageJob` never
  sends to a synthetic customer (the message fails with the non-resendable category
  `synthetic_recipient`, Meta is not called), a synthetic delivery cannot be replayed
  (the admin hides Replay, bulk replay skips it), synthetic products stay out of the public
  menu, the CSV feed, catalog push and reconcile, `ops:report`'s `real` sections leave all of
  it out, and `WhatsappClient` refuses (no HTTP) a missing or non-numeric phone number id.
- `bin/rails ops:purge BEFORE=YYYY-MM-DD CONFIRM=yes` (alias `ops:purge_payloads`) removes
  raw webhook bodies, message text, Meta message ids, order notes and customers' names and
  phone numbers for records older than the date; counts and statuses stay. It skips, and
  reports, work still in use (unapplied deliveries, unsent/failed/unknown messages) unless
  `FORCE=yes`.

Real Meta traffic needs a public HTTPS URL for `/webhooks/whatsapp`; that is
not automated here.

## Deployment

One VPS, Kamal 2, kamal-proxy with Let's Encrypt, PostgreSQL 17 as a Kamal
accessory on the same host, nightly `pg_dump` by cron with an off-host copy.
Config is `config/deploy.yml` (the host is public; the server address comes
from the private secrets file); the procedure, secrets, rotation, restore (into
a new database, never over the live one) and a pre-flight checklist are in
[docs/deploy/RUNBOOK.md](docs/deploy/RUNBOOK.md). Deployed 2026-10-06 to
https://whatsapp.railsfanatics.com, a VPS shared with other applications (both
containers are memory-capped); a backup and a non-destructive restore drill
were run on the live host the same day.

Meta dashboard steps (app, System User token, webhook callback and
subscription, catalog connection) are performed manually by the account owner;
no automation in this repository drives them. `script/meta/check_state.rb` is a
read-only checker (GET requests from a fixed allowlist, no write path).
[docs/operating/PROTOCOL.md](docs/operating/PROTOCOL.md) defines what may be
called an operating period and how scenarios are logged. Verification session 1
(2026-10-06) is done; the operating period has not started. Participant guide,
operator checklist, schedule and evidence rules are next to it. The
tooling its scenarios need (fault injection switch, `ops:repost_delivery`,
`ops:report`, `ops:purge`, the demo simulator) is all on `main`.

## Limitations and non-goals

- One restaurant, one WhatsApp number, one catalog. No multi-tenancy.
- No payments, POS integration, delivery logistics, or LLM. Replies are canned.
- Operator auth is a single shared Basic credential; there are no per-user
  accounts or roles. `by:` records the shared username.
- No template messages. A closed 24h window blocks sends; a template fallback
  would need a Meta-approved utility template and is not implemented.
- One shared host, one database volume, no staging environment, no high
  availability.
- Behaviors that need Meta to settle, listed in
  [docs/v2/meta-research.md](docs/v2/meta-research.md) and
  [docs/v2/CATALOG.md](docs/v2/CATALOG.md), include: whether 131047 arrives
  synchronously, as a `failed` status, or not at all; whether
  `biz_opaque_callback_data` is echoed for catalog cards and for `failed`
  statuses; webhook ordering; the catalog read-back price format; whether Meta
  accepts `out of stock` for a preorder item; review latency and propagation to
  the in-chat catalog; token permissions for `items_batch`; and the real shapes
  of batch status errors.
- V1 fixtures keep field names, nesting and value types, but not raw byte
  layout; signature specs sign re-serialized JSON with a test secret.

## Repository map

| Path | Contents |
|---|---|
| `app/controllers/webhooks/` | Intake: verification handshake and POST handler |
| `app/middleware/webhook_guard.rb` | Body size and signature-header precheck |
| `app/services/webhooks/` | `Ingest`, `DeliveryProcessor`, `MessageHandler`, `StatusHandler`, `Payload` |
| `app/services/whatsapp/`, `whatsapp_client.rb` | `Signature`, `ErrorClassifier`; the only outbound caller of the Cloud API |
| `app/services/messages/outbox.rb`, `conversations/responder.rb`, `orders/builder.rb` | Outbound decisions and order validation |
| `app/services/catalog/` | Field mapping, feed, API client, price parser, reconciler, status |
| `app/jobs/`, `app/services/health/`, `app/services/ops/` | Processing, sending, stall sweeper, catalog jobs; Health snapshot; period report |
| `app/models/` | State machines (`Message`, `WebhookDelivery`, `Order`) via `concerns/status_transitions.rb` |
| `app/controllers/admin/`, `app/views/admin/`, `app/helpers/pii_helper.rb` | Operator UI |
| `config/deploy.yml`, `config/recurring.yml`, `config/initializers/production_config_check.rb` | Deployment, schedules, boot checks |
| `script/backup/`, `script/meta/`, `script/sanitize_v1_payloads.rb` | Backup and restore, read-only Meta check, fixture sanitizer |
| `spec/fixtures/meta/v1/` | Sanitized real V1 payloads; see its README for what is real and synthetic |
| `docs/v2/` | `DESIGN.md` (contract), `meta-research.md` (documentation findings), `CATALOG.md` |
| `docs/deploy/RUNBOOK.md`, `docs/operating/` | Deployment runbook; operating-period protocol and log template |
