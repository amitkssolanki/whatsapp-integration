# Operator checklist

For the operator (Amit). Admin: <ADMIN_URL>. Meta and Facebook account actions are done
only by Amit personally in his own browser; nobody else, and no automated tool, touches
them. See [PROTOCOL.md](PROTOCOL.md) for the rules and [EVIDENCE.md](EVIDENCE.md) for
where records go.

## Daily check (15 minutes at most)

Open `<ADMIN_URL>/admin/health`, go top to bottom, and fill one row of
`daily-check-log-template.md` (private copy). Write zeros as 0.

1. **Red banners.** "Fault injection is ACTIVE" (should be on only during a scenario) and the
   configuration banner "Sending is failing because of configuration". Either one needs an
   action now.
2. **Webhook deliveries.** Failed or partially failed count. Each has a known cause or an
   incident note. Also glance at Unparseable (7d) and Ignored (7d).
3. **Outbound messages by status.** Nothing stuck in pending, sending or retry_scheduled.
4. **Failed sends by category.** Every failure has a known cause.
5. **Unknown outcome.** Each one explained (for example scenario 7) or noted.
6. **Undelivered over 10 minutes.** Explained or noted.
7. **Blocked by the 24h window.** Expected only for scenario 8 and 9 runs.
8. **Retry scheduled.** Empty or a known scenario 6 run.
9. **Orders needing review.** Decide each one; note the issue code.
10. **Orphans and anomalies (7d).** Explained or noted.
11. **Background jobs.** Failed jobs should be 0.
12. **Catalog sync.** Last push and last reconcile, unsynced products, drift (explained).
13. Uptime monitor and the backup heartbeat are green.

Do not run a scenario, deploy or change a switch during the daily check.

## What counts as an incident

Write a note (`incident-template.md`) for any of:

- a failed, unknown, undelivered or blocked message with no known cause;
- a customer-visible difference from what the app recorded, or the reverse;
- a delivery that fails or an order that is wrong without an injected fault;
- the app down, a deploy that goes wrong, a message sent to the wrong person;
- a quality-rating or account-quality signal from Meta (also stop all scenario runs);
- a participant report of anything odd;
- a toggle left on, or any rule in PROTOCOL broken.

Injected and expected scenario outcomes are not incidents; they go in the scenario log.
Label each incident real, injected or simulated. Missing evidence is stated as missing.

## Before a scenario round

- [ ] Participants told the day and time by Amit.
- [ ] Health shows nothing sending (`sending: 0`) and no pending or retry_scheduled messages.
- [ ] If any toggle scenario is planned: set `FAULT_INJECTION_ALLOWED` to `"1"` in the
      deploy config, commit, `kamal deploy`. The "Fault injection" panel appears on Health.
- [ ] If scenario 5 or 12 is planned, prepare the change but do not deploy it yet.
- [ ] Scenario log open; evidence folder for the round created.
- [ ] `ops:report` for the previous period saved (baseline).

## During each scenario

Switch on (tick the kind, tick confirm, Set), run **one** scenario, switch off. The toggle
fires for every matching event for every participant. Tell the participant first. Record
the time on and off. Never leave a toggle on overnight.

## After a scenario round

- [ ] All toggles off; Health shows no red banner.
- [ ] Set `FAULT_INJECTION_ALLOWED` back to `"0"` and redeploy, only when Health shows
      `sending: 0`. Never deploy with anything in flight.
- [ ] Any temporary secret (invalid token) restored and sending confirmed; "Resend all failed
      in auth_config" done if scenario 5 ran.
- [ ] `CATALOG_SYNC_ENABLED` and the changed price restored or the keep-on decision recorded.
- [ ] Meta-side changes made by Amit (a catalog item added) are reverted by Amit.
- [ ] Scenario log rows complete: label, prediction, observation, evidence names.
- [ ] `ops:report FROM=… TO=… FORMAT=md` saved for the round.

## Weekly

- [ ] Check that the nightly backup exists and make the off-host copy (RUNBOOK section 4).
- [ ] Review the incident notes and the daily log for gaps.

## End of period

1. Confirm the criteria in EVIDENCE.md. If unmet, the result is called "live verification
   sessions", with no period metrics.
2. `bin/rails ops:report FROM=<Day 1> TO=<end date> FORMAT=md` (and JSON). Quote `real` only.
3. Tag `ops-end` (pushed only with Amit's approval). Take the final dump into the private archive.
4. After 30 days (purge date), `bin/rails ops:purge BEFORE=YYYY-MM-DD CONFIRM=yes` without
   `CONFIRM` first to preview. Resolve or replay held work before it (PROTOCOL, "After the period").
5. Write results only from `ops:report` and the scenario log.
