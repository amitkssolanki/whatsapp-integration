# Schedule

Three weeks. **Day 1: TBD.** Day 1 is the day the first participant places their first
order. Rounds run on days 1, 8 and 15; the days between are daily checks and natural
traffic only. Rules, labels and scenario definitions are in [PROTOCOL.md](PROTOCOL.md);
the checklist per round is in [OPERATOR_CHECKLIST.md](OPERATOR_CHECKLIST.md).

Actors: **P** participant (messages the demo number), **Op** Amit as operator in the admin,
**Meta** Amit personally in Meta (Commerce Manager); nobody else and no tool touches Meta.
Label: real, simulated, injected. Capture evidence for every run per EVIDENCE.md.

## Scenarios

| # | Scenario | Who acts | Label | Expected design behavior | Evidence to capture | Rounds |
|---|---|---|---|---|---|---|
| 1 | Normal order | P orders; Op accepts | real | Greeting, catalog card, receipt, order recorded without issues, acceptance sent | Order and message ids, admin screenshot, participant screenshot | 1, 8, 15 |
| 2 | Status progression | P (natural) | real | Outbound goes sent, delivered, read | Message status timestamps | 1, 8, 15 |
| 3 | Duplicate webhook | Observed; Op runs `ops:repost_delivery ID=… CONFIRM=yes` | real (observed) / simulated (re-post) | Second copy ignored by idempotency, no second order or reply; re-post labeled `injected:repost` | Delivery ids, `ops:report` duplicate counts | 1, 15 |
| 4 | Replay | Op toggles `processing:order`; P orders; Op switches off and replays | injected failure, real replay | Delivery failed, then replay creates one order | Delivery id, order id, `fault.injected` log | 1, 8 |
| 5 | Outbound permanent failure | Op edits the secrets file with an invalid token and `kamal deploy` (about 1 minute restart; only when nothing is sending), P orders, Op restores the token and redeploys, then "Resend all failed in auth_config" | real | `auth_config` failures, configuration banner, resend succeeds after the fix | Banner screenshot, message ids, time of break and restore | 8, 15 |
| 6 | Retryable failure | Op toggles `send:5xx`; one send; Op switches off before the retry | injected | `retry_scheduled`, then sent | Message id, attempts, timeline | 1, 15 |
| 7 | Ambiguous send | Op toggles `send:read_timeout_after_send` for one send | semi-real (real request, discarded response) | `unknown`, never resent automatically, resolved only if Meta echoes our id or the message id arrives | Message id, how and when it resolved or not | 8, 15 |
| 8 | 24h block | P stays silent over 24h; Op accepts the late order | real | `blocked` (`window_closed`), no call to Meta | Message id, `blocked_at`, no outbound request | 8, 15 |
| 9 | Window override experiment (**once only**) | Op on one blocked message: "Override window (experiment)" | real | Unknown on purpose: sync 131047, async failed, or silent 200; record what Meta does | Message id, response, any `window_disagreement` event | 15 only |
| 10 | Price drift | Op changes a price locally with sync off; P orders at the old price | real | Order recorded at the customer's price, `price_mismatch`, needs review (the sync-and-propagation timing half is measured in 12) | Order id, issue code | 1, 15 |
| 11 | Unknown SKU | **Amit in Meta**: adds one item in Commerce Manager; P orders it; Amit removes it afterwards | real | Line kept, `unknown_sku`, needs review | Order id, issue code, Meta-side screenshot by Amit | 8, 15 |
| 12 | Catalog API push | Op sets `CATALOG_SYNC_ENABLED=true` via redeploy (nothing sending), changes one item's price, waits for the batch to finish, runs "Reconcile now", records when P sees the new price; Op restores the price and decides whether to keep sync on | real | Batch finishes, reconcile shows no unexplained drift, price appears in WhatsApp | Push and reconcile runs, drift count, propagation time seen by P, price before and after | 8, 15 |

Notes:

- Scenario 12 writes to the Meta catalog, so it needs Amit's go-ahead at that time. Without it
  the scenario is not run and not counted.
- Scenario 10 needs sync off; run it before 12 within a round.
- Scenarios 8 and 9 need two silent participants in round 15 (one for each), or a second order
  after a window closes. Tell participants a day ahead.
- Stop all scenario runs on any `account_quality` failure or quality-rating drop.

## Plan

| Day | Date | Round | Do |
|---|---|---|---|
| 1 | TBD | Round 1 | Redeploy with `FAULT_INJECTION_ALLOWED=1`. Scenarios 1, 2, 3, 4, 6, 10. Toggles off, redeploy back to `"0"`. |
| 2-6 | TBD | none | Daily checks. Natural orders only. |
| 7 | TBD | prep | Ask the 8 and 11 participants to stay silent or order a named item. |
| 8 | TBD | Round 2 | Scenarios 1, 2, 4, 5, 7, 8, 11, 12. |
| 9-13 | TBD | none | Daily checks. Weekly backup copy. |
| 14 | TBD | prep | Ask for silence again (8, 9). |
| 15 | TBD | Round 3 | Scenarios 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12. Run 10 before 12. |
| 16-21 | TBD | wrap-up | Daily checks until at least day 14 deployed and every scenario has two runs. If a run failed or was skipped, repeat it in an added round and record why. |
| End | TBD | end | End-of-period steps in the operator checklist. |

Every scenario appears at least twice across the rounds, except 9 (once, by design). If an
earlier run fails to produce usable evidence, the count is not met and the criteria check in
EVIDENCE.md decides the name.
