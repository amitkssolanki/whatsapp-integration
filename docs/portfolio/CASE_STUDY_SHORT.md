# The Local Table: a WhatsApp order channel that tells the truth about delivery

**Problem.** WhatsApp's native Catalog and Cart lets customers order inside a chat. But webhooks arrive at least once, and a `200 OK` from the send API does not mean a message arrived.

**Challenge.** My first version took three real orders, and its own logs showed it could not be trusted. It discarded all 36 status webhooks, answered 7 failures with HTTP 200 and kept them only in a log line, stored placeholder text instead of Meta message ids, and had no defence against the duplicate delivery Meta really sent.

**Solution.** I rebuilt it on Rails 8.1 and PostgreSQL. Every webhook is signature-checked and durably stored before it is interpreted, and each logical event is applied exactly once. Outbound messages go through an outbox with a forward-only status lifecycle, and an ambiguous send becomes `unknown` instead of being resent. Failures are classified and shown to an operator.

**Real-world verification.** On 2026-10-06 I ran a session against real Meta traffic as the only customer. The first catalog reply failed with error #131009; its stored details pointed straight at a disabled catalog setting, the same cause V1's log had held unnoticed. I fixed it by hand in Meta's settings; the next "Hi" got a working catalog card. The session processed 10 real webhook deliveries exactly once.

**Result.** 1,112 RSpec examples, 0 failures on the current code; 1,111 at release commit `33b18a5`, with GitHub CI green; and a deployed HTTPS environment. Not verified against Meta: catalog push and the 24-hour window. No operating period (planned, intentionally not pursued), no uptime data, no real customers. Built with AI-directed development (Claude Code); Meta account actions done by hand.

- [Repository](https://github.com/amitkssolanki/whatsapp-integration)
- [Full case study](https://github.com/amitkssolanki/whatsapp-integration/blob/main/docs/portfolio/CASE_STUDY.md)
- [Field guide](https://amitsolanki.com/writing/whatsapp-catalog-cart-field-guide/)
