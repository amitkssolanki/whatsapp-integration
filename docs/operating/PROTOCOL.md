# Operating period protocol

Related: [PARTICIPANT_GUIDE.md](PARTICIPANT_GUIDE.md) (what participants are told),
[OPERATOR_CHECKLIST.md](OPERATOR_CHECKLIST.md) (daily check, incidents, rounds, end of period),
[SCHEDULE.md](SCHEDULE.md) (3-week plan, who acts per scenario), [EVIDENCE.md](EVIDENCE.md)
(what is kept where, criteria check). Templates: [scenario-log-template.md](scenario-log-template.md),
[daily-check-log-template.md](daily-check-log-template.md), [incident-template.md](incident-template.md).

**Status:** Verification Session 1 completed 2026-10-06 (owner only). Operating period: not started.

The operating period exists to observe how the real platform behaves against V2's
assumptions, and to show that V2 records the truth: **zero unexplained differences**
between what a customer saw on their phone and what the app recorded.

Nothing here may be fabricated, back-filled or rounded up. Missing evidence is
reported as missing.

## What we are allowed to call it

| Achieved | Name |
|---|---|
| ≥ 14 days deployed on the stable domain, ≥ 2 people besides Amit placing orders, every scenario below run at least twice (scenario 9 once by design) | **operating period** |
| Anything less | **live verification sessions** (report per-session outcomes only; no period metrics, no latency distributions) |

## Participants and consent

- Only people who agreed in advance, in their own words, to message the demo number.
  Amit contacts them himself; Claude never messages anyone.
- Meta and Facebook account actions (for example adding a catalog item in Commerce Manager)
  are performed only by Amit personally in his own browser. Nobody else is asked to touch
  Meta, and no automated tool operates it.
- They are told: it is a fictional restaurant, orders are not real, their phone number
  and name are stored on a private server until the purge date, and screenshots/video
  will be masked.
- No marketing, no messages to anyone who has not messaged the number first.
- Never provoke rate limits or quality signals (no burst-testing one person, no
  repeated sends to non-responding numbers). Stop all scenario runs on any
  `account_quality` failure or quality-rating drop.

## Daily check (about 15 minutes)

1. Open `/admin/health`. Record the day in the daily check log (private copy of
   `daily-check-log-template.md`); write an incident note for anything red without a cause.
2. Every failed delivery or message has a known cause, or an incident note.
3. Undelivered > 10 min and `unknown` messages: explained or noted.
4. Catalog: last reconcile drift explained.

The Health sections, in page order, and the full checklist are in `OPERATOR_CHECKLIST.md`.

## Scenarios

Each run is logged in a copy of `docs/operating/scenario-log-template.md` kept in the private evidence archive with: date, scenario, how it
was induced, **real / simulated / injected**, what the design predicts, what was
actually observed, links (record ids, screenshot names). Run each at least twice,
about a week apart (scenario 9 once only). SCHEDULE.md says which scenarios run in which round.

| # | Scenario | How it is induced | Label |
|---|---|---|---|
| 1 | Normal order | A participant orders from the catalog | real |
| 2 | Status progression | Natural (sent → delivered → read) | real |
| 3 | Duplicate webhook | Observed naturally (counted in `ops:report` `real`); plus `bin/rails ops:repost_delivery ID=<delivery id> CONFIRM=yes`, which re-ingests one stored delivery's exact bytes and signature (not over HTTP) as a new delivery labeled `injected:repost` | real (observed) / simulated (re-post) |
| 4 | Replay | Switch on `processing:order` (Health → Fault injection), a participant orders, the delivery fails, switch off, replay from Health → one order | injected failure, real replay |
| 5 | Outbound permanent failure | Amit temporarily sets an invalid token for ~10 minutes (edit the private secrets file, `kamal deploy`, about 1 minute restart, only when Health shows nothing sending) → `auth_config`; restore the same way; "Resend all failed in auth_config" | real |
| 6 | Retryable failure | Switch on `send:5xx`, trigger one send (every send fails while it is on), switch off before the retry fires → retry_scheduled → succeeds | injected |
| 7 | Ambiguous send | Switch on `send:read_timeout_after_send` for one send (the real request is sent, the response is discarded) → `unknown` → resolved only if Meta echoes our id or the message id arrives | semi-real |
| 8 | 24h block | A participant stays silent > 24h, then the operator accepts a late order → `blocked`, no call to Meta | real |
| 9 | Window override experiment | Once, on a blocked message, "Override window (experiment)" → observe what Meta actually does (sync 131047, async failed, or silent 200) | real |
| 10 | Price drift | With `CATALOG_SYNC_ENABLED=false` (the deployed default), change a price locally, participant orders at the old price → `price_mismatch`; set it to `"true"` in `config/deploy.yml`, redeploy (when Health shows `sending: 0`), sync, and time when WhatsApp shows the new price | real |
| 11 | Unknown SKU | Amit (personally, in Meta) adds one item directly in Commerce Manager; participant orders it → `unknown_sku`; Amit removes it afterwards | real |
| 12 | Catalog API push | Amit sets `CATALOG_SYNC_ENABLED=true` via redeploy (nothing sending), changes one item's price, waits for the batch to finish, runs reconcile, records the propagation time a participant sees, restores the price and decides whether to keep sync on. Needs Amit's go-ahead at that time because the app then writes to the Meta catalog | real |

Fault injection toggles are switched on the Health page ("Fault injection" panel, visible
only when `FAULT_INJECTION_ALLOWED=1` was deployed; the operator is recorded). They are read
from the database on every check, so no redeploy is needed (a redeploy restarts the app and
turns in-flight sends into `unknown`). **A toggle fires for every matching event for every
participant while it is on**, so: switch on, run one scenario, switch off. Tell the participant
before you switch on; never leave a toggle on overnight. Every injected event is labeled in the
log (`fault.injected`) and on the affected record ("injected" / `[injected]` / `injected_faults`),
the Health page shows a red banner while any toggle is on, and `ops:report` keeps injected rows
out of its `real` numbers. In production they work only with `FAULT_INJECTION_ALLOWED=1`, which is redeployed on for scenario rounds and back to `"0"` after them; the
`FAULT_INJECT` environment variable is not used there and the app refuses to boot with it set.
Changing `FAULT_INJECTION_ALLOWED`, `CATALOG_SYNC_ENABLED` or `DEMO_MASK_PII` needs a redeploy
(RUNBOOK section 3): do it when Health shows `sending: 0`.

## Synthetic data (the seeded operator UI)

A fresh deployment has an empty operator UI. `bin/rails demo:seed_integration CONFIRM=yes`
(run it inside the production app container; docs/deploy/RUNBOOK.md has the deployment commands)
fills it with **clearly synthetic** data. It is safe next to the real Meta token, but it is
not evidence: **never quote it, never screenshot it as if real, and never put it in the
scenario log.** Everything it creates is flagged `synthetic` (customers named "Demo Customer N"
with numbers in the fictional 1 555 010 xxxx range, deliveries, `sim.in.N` / `sim.out.N` message ids,
DEMO-* products in the category "Demo items (synthetic)") and shows a "synthetic" badge in the admin.

- **What it does.** Removes all earlier synthetic data, then plays 12 scenarios through the real
  webhook controller, jobs and state machines: greeting and catalog card, clean order accepted,
  price mismatch, unknown SKU, unavailable product, invalid quantity (all four needing review),
  a permanent send failure (fake 131026), a blocked send outside the 24h window, an ambiguous
  send left `unknown`, a duplicate status, an injected processing failure replayed inside the
  run, and a rejected order. Timestamps are spread over the last days. Reruns give the same counts.
- **How it stays safe.** It runs in-process only: WhatsApp and catalog requests are answered by an
  in-process fake, the token / phone number id / webhook signing secret are run-local fakes (the
  real ones are restored afterwards), Solid Queue is not used, fault injection is a
  process-local override (the stored toggles on the Health page are neither read nor written), and
  `Net::HTTP` cannot connect while it runs. It runs in one transaction and rolls everything back,
  raising, unless the end state holds: no synthetic outbound message pending/sending/retry_scheduled,
  no Solid Queue job for it, no network attempt, only synthetic customers, deliveries and products.
  Without `CONFIRM=yes` it prints what it would replace and changes nothing. It never selects a
  non-synthetic row.
- **Guards that always hold for synthetic rows** (also when nobody runs the seed): `SendMessageJob`
  never sends to a synthetic customer (the message fails with `synthetic_recipient`, which is not
  retryable and not resendable; log `send.synthetic_refused`); a synthetic delivery cannot be replayed
  (`webhook.replay_refused` reason `synthetic`; the admin hides Replay and bulk replay skips it);
  synthetic products are excluded from the public menu, the CSV feed, catalog push (including
  Sync now) and reconcile, and never trigger the debounced push; a real customer ordering a
  DEMO-* SKU gets `unknown_sku`. Separately, `WhatsappClient` refuses, without any HTTP, to send
  when the phone number id is missing or not all digits.
- **In the numbers.** `ops:report` leaves synthetic data out of every `real` section (and out of
  the `injected` summary); `all` still counts it, so the report reconciles with the database.
- **Removing it.** `bin/rails demo:purge_synthetic CONFIRM=yes` deletes exactly the synthetic
  rows (the same code as the seed's reset) and leaves everything else untouched. The old
  "Jordan (demo)" customer that `db:seed` used to create is flagged synthetic by the migration
  that added the flag; the seed no longer creates demo customers.

## Metrics

`bin/rails ops:report FROM=… TO=… FORMAT=md` produces every metric from the database.
Medians and ranges only; no percentiles on small samples.

Every section is computed twice. **`real`** counts only rows that show real platform
behavior: nothing with an injected fault or a re-post (`injected_faults` not empty) and, for
outbound messages, nothing sent to simulated "Demo Customer" customers, and, since
`demo:seed_integration`, nothing synthetic: no deliveries flagged `synthetic`, no messages or
orders of synthetic customers. **`all`** counts every
row. An **`injected`** summary lists how many rows carry each label. Quote `real` in results
(duplicates, failures, retries, unknowns, error categories); latency comes from real rows only.
The Markdown output shows `real` first, then `all`, then the injected summary.
A re-posted delivery therefore never inflates the real duplicate count.

## Evidence retained (outside the public repo until sanitized)

- `ops:report` JSON + Markdown for the whole period and for each scenario round.
- The scenario log; incident notes.
- Masked admin screenshots per scenario (`DEMO_MASK_PII=1`); phone screenshots from
  participants only with consent; Meta-side screenshots taken by Amit.
- Sanitized payload samples for any new event shape (run them through
  `script/sanitize_v1_payloads.rb`-style scrubbing before they enter the repo). The script
  replaces phone numbers, Meta ids, user ids, names, usernames, free text and order notes
  (only the empty note and plain greetings survive); re-running it on the archived V1 log
  reproduces the committed fixtures byte for byte.
- Git tags `ops-start` and `ops-end` (pushed only with Amit's approval).
- A final database dump in the private archive.

## After the period

1. Tag `ops-end`, take the final dump into the private archive.
2. Purge personal data for everything before the purge date (30 days after the end date),
   keeping the aggregates: `bin/rails ops:purge BEFORE=YYYY-MM-DD CONFIRM=yes` (without
   `CONFIRM=yes` it only prints what it would do; `ops:purge_payloads` is the old name).
   It removes:
   - `webhook_deliveries`: the raw body, and the Meta message ids in the item results
     (replaced by a fingerprint);
   - `messages`: text body, payload, Meta message id and error details;
   - `orders`: the order note;
   - `customers` whose last activity is before the date: name and phone number (the user id
     becomes `purged:<id>`).

   It keeps statuses, timestamps, counts, error codes/categories, body hashes and item
   results, so `ops:report` gives the same numbers afterwards. It does **not** purge work still
   in use, and says so: deliveries `received`/`processing`/`failed`/`partially_failed`,
   outbound messages `pending`/`sending`/`retry_scheduled`/`failed`/`unknown`, and customers
   with such a message. Resolve or replay those first (the daily check), or add `FORCE=yes`
   to purge them anyway (then they can never be replayed or resent). Purged deliveries cannot
   be replayed; purged messages cannot be resent.
3. Write results only from `ops:report` and the scenario log.
