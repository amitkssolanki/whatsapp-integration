# Case study: building a WhatsApp order channel that tells the truth about delivery

> **At a glance**
>
> - **What it is:** "The Local Table", a WhatsApp Catalog + Cart order channel for a fictional restaurant (20 real dish names and photos from TheMealDB and TheCocktailDB). A production-oriented reference implementation.
> - **Stack:** Ruby 3.4.7, Rails 8.1.4, PostgreSQL 17, Solid Queue (in the primary database, run inside Puma), Faraday, RSpec, Kamal 2.12, kamal-proxy with Let's Encrypt, Thruster, Docker.
> - **Scope:** webhook intake, order capture and validation, outbound messaging with tracked delivery, an operator UI, a catalog sync path (built, off by default), deployment to a shared VPS. One restaurant, one number, one operator.
> - **Evidence:** 1,111 RSpec examples, 0 failures; CI green on `c6d63ee`; one real verification session against Meta on 2026-10-06 (10 real webhook deliveries, all processed exactly once); V1's real traffic from 2026-08-08 as the starting point.
> - **Links:** [Repository](https://github.com/amitkssolanki/whatsapp-integration) · [Live integration environment](https://whatsapp.railsfanatics.com) · [Field guide (V1 article)](https://amitsolanki.com/writing/whatsapp-catalog-cart-field-guide/) · [Verification evidence](../evidence/2026-10-06-verification-session-1.md) · [Claims and evidence](../evidence/PORTFOLIO_CLAIMS.md)

I built this project twice. The first version took three real orders, and its own logs and database then showed that it could not be trusted. The second version is a rebuild around that evidence, run afterwards against real Meta traffic. This document covers what failed, what I changed and why, what I verified, and what I did not.

On method: I built this with AI-directed development (Claude Code), and every commit carries a Claude co-author trailer. Every action in Meta's and Facebook's consoles was done by me, by hand.

## The problem

WhatsApp has a native Catalog and Cart. A business links a product catalog to its number; a customer opens it inside the chat, adds items and sends the cart, which reaches the business as a webhook carrying an `order` message. There is no checkout page and no payment form of my own: the customer stays in the conversation they already have.

The happy path is short: show a catalog, receive a cart, record the order, reply. V1 did that, with a CSV feed for Commerce Manager, a webhook that turned carts into orders, and replies including a catalog card in answer to "hi".

The difficulty is everything around the happy path. Meta's webhooks arrive at least once, not necessarily in order. A `200 OK` from the send API means a request was accepted, not that a message reached anyone. The only evidence of what happened to a message is a later status webhook, and those can be duplicated, skipped or reordered. An integration that treats each response as final truth is wrong in ways it cannot see.

## What V1 revealed

V1 ran live on 2026-08-08. Meta sent 52 webhook POSTs: 36 status webhooks, 13 text messages (one of them Meta's own dashboard test sample) and 3 orders. The orders were real ($25.00, $16.50 and $46.50). I preserved the logs, a database dump and screenshots outside the repository with SHA-256 checksums, then read them as evidence. Six findings came out of it.

**All 36 status webhooks were discarded.** The processor skipped any change without `messages`, so every `sent`, `delivered` and `read` event, the only record of delivery, vanished on arrival.

**Seven processing errors were answered with HTTP 200 and recorded only in the log.** Five were Meta error #131009 on catalog cards, so a customer who said "hi" got nothing; the five had three different causes, described below. One was #131030, raised while replying to Meta's dashboard test sample. One was a Ruby `TypeError` from a name collision, triggered by a local test POST. (#133010, account not registered, also appears in the log.) Since the controller answered 200 regardless, Meta saw success and did not retry, and the application had nothing stored to retry from.

**Five #131009 errors, three causes, one log line each.** Meta's `error_data.details` showed three were a request bug (a catalog card sent without a thumbnail), one was that the catalog was not enabled in WhatsApp Commerce Settings, and one was a thumbnail product not found in the catalog. V1 recorded each only as a log line and could not tell them apart. That detail matters again in the verification session below.

**The app could not know what it had sent.** The database held 10 outbound rows; seven held the literal placeholder "(auto-reply sent)", and none had a Meta message id.

**Meta delivered the same `delivered` status twice**, in two separate POSTs from two Meta hosts within the same second. V1 had no unique constraint on message ids.

**My test fixture did not match reality.** I had written an order payload by hand with string quantity and price and a non-empty note. Real carts send numeric quantity and price and an empty note. The tests passed against a payload real traffic never produced.

These are V1's actual failures, not V2 virtues retrofitted onto it. Each maps to a decision below.

## The redesign

The premise: the platform's responses cannot be taken at face value, so the system must store first, interpret later, and track the real fate of everything it sends.

**Durable, store-first ingestion.** The handler verifies an HMAC-SHA256 signature over the raw body (constant-time, fail closed), then stores the raw delivery and enqueues the processing job in one transaction, then returns 200. Solid Queue lives in the same PostgreSQL database, which makes that single transaction possible. A database failure returns 500 so Meta retries. Unsigned requests get 401 and are not stored. Bodies over 3 MB get 413 before Rails sees them, enforced by Rack middleware and by a kamal-proxy limit. *Why:* V1 answered 200 for failed work and kept nothing to retry from.

**Per-item idempotency.** Each logical item (a message, a status) is keyed by its Meta message id under a unique constraint, applied with `INSERT … ON CONFLICT DO NOTHING` in a per-item transaction. A duplicate skips all side effects, and one bad item does not roll back the others in the same delivery. *Why:* V1 saw the same status arrive twice within a second and had no defence.

**Asynchronous processing and safe replay.** Interpretation happens in a job, not in the request. Stored deliveries can be replayed from the operator UI, with the signature re-verified. *Why:* once raw deliveries are kept, a processing bug is recoverable instead of permanent.

**Outbox and claim.** A decision to send creates a pending outbound row with an idempotency key and enqueues a send job, atomically. The job claims the row with a conditional `UPDATE`, and Meta is never called inside a database transaction. *Why:* V1 sent confirmations inline from the webhook request and recorded a placeholder.

**Ambiguous outcomes become `unknown` and are never resent.** If a send times out after the request left, I do not know whether Meta processed it. The row is marked `unknown` and shown to the operator. *Why:* resending a possibly delivered message to a customer is worse than showing an operator an honest question mark.

**A forward-only status lifecycle.** Messages move accepted, sent, delivered, read, never backwards, and each timestamp is written once. Late, duplicate and out-of-order statuses are handled; a `failed` arriving after `delivered` is recorded as an anomaly. *Why:* V1 discarded every status, and Meta's real behaviour includes duplicates.

**Correlation.** Each outbound message carries `biz_opaque_callback_data` set to our own message id, as a secondary key; the Meta id stays primary. *Why:* a second way to match a status to its row, which I wanted to check against real traffic rather than assume.

**An error taxonomy.** Meta error codes, and the details field where a code is overloaded, map to retryable, permanent, config or ambiguous. Retry state is visible, and an operator can resend only for categories a human can fix. *Why:* V1's seven errors were different kinds of problem, all handled the same way: logged and forgotten.

**A 24-hour window guard.** Free-form messages are allowed only within 24 hours of the customer's last message. V2 checks right before sending, with a five-minute safety margin. *Why:* a check made at decision time can be stale by the time a queued job runs.

**Order validation.** An order is always recorded. Mismatched price, unknown SKU, unavailable item, invalid quantity, currency or catalog flag it `needs_review`, and the price the customer saw is honoured. *Why:* dropping a real customer's order because a field looks odd is the worst available failure, and the fixture mismatch showed I could not predict real payloads.

**An operator UI.** Fail-closed HTTP Basic authentication; Orders (accept, reject); Conversations (delivery ticks); Deliveries (replay); and Health, listing failures, `unknown` sends, undelivered messages, blocked sends, catalog drift and failed jobs. A switch masks personal data.

**Catalog sync, built and off.** V2 can push the catalog through Meta's API (`items_batch` with status polling) and run a read-only reconcile that reports drift. Both are off by default and the CSV feed remains the fallback. The push path is not verified against Meta; it is covered by specs only.

**Security hardening.** Signature checks fail closed, admin pages require credentials (the admin inherited from V1 had none; see below), request size is capped, and secrets sit in a private file, with fail-closed placeholders until the real Meta values existed.

## Real-world verification

On 2026-10-06, with V2 deployed, I ran one session against real Meta traffic, as the only customer. I configured the webhook in Meta's use-case app flow myself.

The new business number was verified but not registered: WhatsApp reported it as "not on WhatsApp" until I called `POST /register`. After that it showed Cloud API as connected.

I sent "Hi". The app tried to reply with the catalog card, and the send failed with Meta error #131009, "Parameter value is not valid". V1's log held this code five times, with three different details, one of them this exact cause; V1 kept errors only in a log line and could not tell them apart. V2 stored the code and the details on the message, so the diagnosis took no digging.

The error's `error_data.details` said the catalog must be both linked and enabled in WhatsApp Commerce Settings. The new number's commerce settings had the catalog off, though it was linked at account level. Only a human in Meta's console can make that configuration fix, and I made it by hand. Nothing was retried automatically: my next "Hi" got a working catalog card.

V2 was wrong here too. It initially filed the failure as `request_invalid`, the wrong category, because fixing the request cannot help. I corrected it to `account_config` the same day. The failure was stored, visible and diagnosable, and the diagnosis fed back into the taxonomy.

After the fix, the session produced:

- **Order #9**, two items ($5.00 and $19.50, total $24.50), prices equal to the catalog, review clear.
- **Three tracked outbound messages.** The catalog card went accepted, sent, read (read after about a second). The receipt went accepted, sent, read. The acceptance notice, sent after I accepted the order in the admin UI, went accepted, sent, delivered, read.
- **`delivered` skipped when a message was read immediately**, twice, and present once. A system that required `delivered` before `read` would have broken.
- **The correlation id echoed on all seven real status webhooks**, for an interactive `catalog_message` and for text, each equal to our message id.
- **Catalog read access** confirmed live: 20 products, prices read back as "$5.00".

In total: 10 real webhook deliveries (3 messages, 7 statuses), all processed exactly once, with 0 duplicates, 0 orphans and 0 failed jobs. Every send took one attempt.

## Engineering quality

**Tests and CI.** 77 spec files, 1,111 examples, 0 failures, locally and on GitHub CI at `c6d63ee`. Highlights: real-thread concurrency specs (webhook dedupe, send claim, customer creation); all 24 orderings of accepted, sent, delivered and read end at `read` with every timestamp; specs for a stale status arriving after a resend; and a synthetic seed that runs in a self-checking transaction and rolls back if any guarantee is violated, including any network attempt. Three CI jobs, all green: lint (RuboCop), security (Brakeman with `--exit-on-warn`, and bundler-audit) and RSpec on PostgreSQL 17. From V1 to the release commit `c6d63ee` there were 125 commits, 20 of them merges; each phase was a branch merged with `--no-ff`.

**Reviews.** Four AI review rounds by a separate reviewer model (two on security and correctness, one pre-deploy, one pre-release) found real defects, all fixed:

- A late status for an old Meta id could be applied to a message that had since been resent.
- A retryable failure could resend a message Meta had already processed.
- The payload purge did not remove the personal data participants would be promised.
- Injected-fault labels could be lost.
- The real business number (one spec line) and the server address (deploy history) were in the repository; both were removed before the first public push.

Separately, the admin inherited from V1 had no authentication until the operator-UI phase added fail-closed auth.

**Defects found only by running it:**

- On the first production deploy, the stall sweeper's helper method was named `enqueue`, shadowing `ActiveJob#enqueue`, so `StallSweeperJob.perform_later` raised (the scheduled path happened to work). Fixed, with a regression spec.
- On the first public CI run, 133 specs failed because `db:prepare` seeds a fresh test database. CI now loads the schema only.
- During the verification session, the verify token appeared in the web server's access log: Thruster logged it though Rails filters it. I turned Thruster's request log off. The shared reverse proxy keeps one line, and it has no redaction option.

**Deployment.** Kamal to a shared VPS behind kamal-proxy with Let's Encrypt; app capped at 768 MB and Postgres at 256 MB; the Solid Queue supervisor, dispatcher, worker and scheduler running, with a recurring stall sweeper. On the live host I verified: valid HTTPS; `/up` 200; HTTP redirecting to HTTPS; a wrong verify token 403; an unsigned POST 401; a forged signature 401; a 4 MB body 413; admin 401 without or with wrong credentials and 200 with correct ones; a harmless job processed; an unloadable job recorded as failed, then discarded. A container restart was healthy again in about six seconds with jobs processing and data intact. A `pg_dump` backup restored into a scratch database with identical row counts and schema version (restore drill, 2026-10-06). A nightly `pg_dump` by cron is installed (first scheduled run 2026-10-07); an off-host copy is a documented procedure only, and there is no heartbeat or uptime monitor.

**Synthetic data kept apart.** `ops:report` separates real from injected traffic, and fault-injection labels are permanent. A demo simulator and a production-safe synthetic seed (12 scenarios, zero real HTTP calls) show scenarios Meta will not produce on demand; synthetic customers can never be sent to Meta, so they cannot contaminate real metrics.

## What remains unverified, and what I do not claim

- **No multi-week operating period.** It was planned in the original validation plan and intentionally not pursued (decision 2026-10-07) because it was not needed for the portfolio objective.
- **No reliability statistics.** No long-term reliability, uptime, latency or volume figures; no production-scale traffic; no real customers besides me. This is not a commercial production product.
- **Not verified against Meta:** Catalog API push and reconcile; correlation-id echo on `failed` statuses; a real duplicate delivery handled by V2 (the real duplicate came in V1); the 24-hour window block and override; real price-mismatch, unknown-SKU, unavailable or odd-quantity orders; real retryable or ambiguous send failures. These are covered by specs and the synthetic seed, which is simulation, and I label it that way.
- **Scope limits.** Template messages are not implemented. One restaurant, one number, one operator.

## Outcome

V2 demonstrates a WhatsApp integration built on the assumption that Meta's responses are unreliable, grounded in real V1 evidence rather than caution alone. It stores every delivery before interpreting it, applies each logical event once, tracks each outbound message to its real fate, and turns failures into visible, categorised, recoverable states. A real failure during verification, fixed by hand in Meta's console, was diagnosed from the system's own records. It is feature-complete for the demonstrated scope (catalog card, cart to order, operator decision, customer notice, delivery tracking), verified against real Meta traffic in one session.

For a real deployment I would, in order:

1. Run a controlled operating period with several participants over weeks (planned originally, not pursued here), and judge reliability on that evidence.
2. Verify the unverified list against Meta, starting with catalog push, the `failed` correlation echo and a naturally occurring duplicate.
3. Add template messages, so the business can reach customers outside the 24-hour window.
4. Support more than one number and operator, with roles and per-restaurant configuration.
5. Add alerting on the Health signals, so no one has to look.

Repository: https://github.com/amitkssolanki/whatsapp-integration
