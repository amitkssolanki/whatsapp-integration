# Evidence

What is kept, where, and what may be called an operating period. Rules come from
[PROTOCOL.md](PROTOCOL.md).

## Public repo

- Templates: `scenario-log-template.md`, `daily-check-log-template.md`, `incident-template.md`.
- Sanitized session write-ups under `docs/evidence/`.
- Sanitized payload samples for new event shapes only, after scrubbing.

No phone numbers, Meta ids, names or message text from real people go here.

## Private archive (outside the repo)

| Item | Name |
|---|---|
| Daily check log | `daily-check-log.md` |
| Scenario log | `scenario-log.md` |
| Incident notes | `incident-YYYY-MM-DD-NN.md` |
| `ops:report` output, whole period and per round | `ops-report-YYYY-MM-DD_to_YYYY-MM-DD.md` / `.json` |
| Masked admin screenshots (`DEMO_MASK_PII=1`) | `YYYY-MM-DD-<scenario #>-<what>.png` |
| Participant phone screenshots (with consent) | `YYYY-MM-DD-<scenario #>-phone.png` |
| Meta-side screenshots (taken by Amit) | `YYYY-MM-DD-meta-<what>.png` |
| Final database dump | `final-YYYY-MM-DD.dump` |

Dates are UTC, `YYYY-MM-DD`.

## Labels

Every scenario run and every piece of evidence is **real**, **simulated** or **injected**.
Synthetic demo data ("Demo Customer N", "synthetic" badge) is none of these: it is not
evidence and is never quoted.

## Rules

- Never fabricate, back-fill or round up.
- Zeros are reported as zeros.
- Missing evidence stays missing and is said to be missing.
- Numbers come from `ops:report` (`real` section) and the scenario log only.
- Nothing public contains phone numbers, Meta ids, names or participant messages.
- Screenshots shown publicly are masked.

## Criteria check

Tick all before using the name "operating period".

- [ ] 14 or more days deployed on the stable domain (Day 1 = first participant's first order).
- [ ] At least 2 participants besides Amit placed orders.
- [ ] Every scenario in the schedule ran at least twice (scenario 9 is once only by design).
- [ ] Daily short Health checks logged for every day (gaps listed).
- [ ] Incident notes exist for every incident, or "none" is stated.
- [ ] Every run labeled real, simulated or injected.

All ticked: **operating period**. Anything missing: **live verification sessions**: report
per-session outcomes only, with no period metrics and no latency distributions.
Verification Session 1 (2026-10-06, owner only) is a live verification session, not an
operating period.
