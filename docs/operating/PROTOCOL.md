# Operating period protocol

The operating period exists to observe how the real platform behaves against V2's
assumptions, and to show that V2 records the truth: **zero unexplained differences**
between what a customer saw on their phone and what the app recorded.

Nothing here may be fabricated, back-filled or rounded up. Missing evidence is
reported as missing.

## What we are allowed to call it

| Achieved | Name |
|---|---|
| ≥ 14 days deployed on the stable domain, ≥ 2 people besides Amit placing orders, every scenario below run at least twice | **operating period** |
| Anything less | **live verification sessions** (report per-session outcomes only; no period metrics, no latency distributions) |

## Participants and consent

- Only people who agreed in advance, in their own words, to message the demo number.
  Amit contacts them himself; Claude never messages anyone.
- They are told: it is a fictional restaurant, orders are not real, their phone number
  and name are stored on a private server until the purge date, and screenshots/video
  will be masked.
- No marketing, no messages to anyone who has not messaged the number first.
- Never provoke rate limits or quality signals (no burst-testing one person, no
  repeated sends to non-responding numbers). Stop all scenario runs on any
  `account_quality` failure or quality-rating drop.

## Daily check (about 15 minutes)

1. Open `/admin/health`. Note anything red in the scenario log (date, what, link).
2. Every failed delivery or message has a known cause, or an incident note.
3. Undelivered > 10 min and `unknown` messages: explained or noted.
4. Catalog: last reconcile drift explained.

## Scenarios

Each run is logged in a copy of `docs/operating/scenario-log-template.md` kept in the private evidence archive with: date, scenario, how it
was induced, **real / simulated / injected**, what the design predicts, what was
actually observed, links (record ids, screenshot names). Run each at least twice,
about a week apart.

| # | Scenario | How it is induced | Label |
|---|---|---|---|
| 1 | Normal order | A participant orders from the catalog | real |
| 2 | Status progression | Natural (sent → delivered → read) | real |
| 3 | Duplicate webhook | Observed naturally (counted in `ops:report`); plus re-posting one captured, correctly signed delivery body to the endpoint | real (observed) / simulated (re-post) |
| 4 | Replay | Enable `FAULT_INJECT=processing:order`, a participant orders, the delivery fails, disable, replay from Health → one order | injected failure, real replay |
| 5 | Outbound permanent failure | Amit temporarily rotates to an invalid token for ~10 minutes → `auth_config`; restore; "Resend all failed in auth_config" | real |
| 6 | Retryable failure | `FAULT_INJECT=send:5xx` for one send → retry_scheduled → succeeds | injected |
| 7 | Ambiguous send | `FAULT_INJECT=send:read_timeout_after_send` (the real request is sent, the response is discarded) → `unknown` → resolved only if Meta echoes our id or the message id arrives | semi-real |
| 8 | 24h block | A participant stays silent > 24h, then the operator accepts a late order → `blocked`, no call to Meta | real |
| 9 | Window override experiment | Once, on a blocked message, "Override window (experiment)" → observe what Meta actually does (sync 131047, async failed, or silent 200) | real |
| 10 | Price drift | `CATALOG_SYNC_ENABLED=false`, change a price locally, participant orders at the old price → `price_mismatch`; re-enable, sync, and time when WhatsApp shows the new price | real |
| 11 | Unknown SKU | Amit adds one item directly in Commerce Manager; participant orders it → `unknown_sku` | real |

Fault injection toggles are environment variables read at runtime, logged on every
use, and must be off outside a scenario. Every injected event is labeled in the log.

## Metrics

`bin/rails ops:report FROM=… TO=… FORMAT=md` produces every metric from the database.
Medians and ranges only; no percentiles on small samples.

## Evidence retained (outside the public repo until sanitized)

- `ops:report` JSON + Markdown for the whole period and for each scenario round.
- The scenario log; incident notes.
- Masked admin screenshots per scenario (`DEMO_MASK_PII=1`); phone screenshots from
  participants only with consent; Meta-side screenshots taken by Amit.
- Sanitized payload samples for any new event shape (run them through
  `script/sanitize_v1_payloads.rb`-style scrubbing before they enter the repo).
- Git tags `ops-start` and `ops-end` (pushed only with Amit's approval).
- A final database dump in the private archive.

## After the period

1. Tag `ops-end`, take the final dump into the private archive.
2. Purge raw webhook bodies and message payloads older than 30 days after the end date
   (aggregates and statuses stay).
3. Write results only from `ops:report` and the scenario log.
