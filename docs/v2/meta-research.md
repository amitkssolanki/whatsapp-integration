# What Meta documents (and does not) for V2's assumptions

Documentation-only research, 2026-10-06. No account access, no API calls. Meta's
WhatsApp docs now live under
`developers.facebook.com/documentation/business-messaging/whatsapp/`. Confidence:
**H** documented directly, **M** documented indirectly or by reputable secondary
sources, **L** inferred or contradicted. Where the docs are silent, V2 handles every
plausible behavior instead of picking one.

## Messaging and webhooks

| Topic | Finding | Conf. | Design consequence |
|---|---|---|---|
| Webhook delivery | Failed deliveries are retried with decreasing frequency for up to 7 days; retries can produce duplicates. No ordering guarantee is documented; `delivered` can be skipped when a message is read immediately. V1's log independently shows a real duplicate. | H | Store every delivery; dedupe per item; forward-only statuses. |
| Signature | `X-Hub-Signature-256` is HMAC-SHA256 of the raw body with the app secret. Meta signs its own (escaped-unicode) serialization, so only the exact received bytes verify. | H | Verify `raw_post`; store the raw body byte-for-byte; never re-serialize before verifying. |
| Payload size | Up to 3 MB. | H | Text column; no special handling. |
| Send idempotency | No idempotency key or dedupe exists for `/messages`. | H (absence) | Ambiguous sends become `unknown`; never auto-resent. |
| `biz_opaque_callback_data` | Supported on free-form messages since Nov 2023, up to 512 chars, echoed on status webhooks "if set". `catalog_message` is not named, and echo on `failed` is not documented. | M | Sent on every message, used only as a secondary correlation key. Meta's message id is primary. An ambiguous send with no echo stays `unknown`. |
| 24h window / 131047 | The window runs from the customer's last message or call, per business number. Whether 131047 comes back synchronously, as a `failed` status, or both is undocumented, and secondary sources disagree. | M/L | Local guard before sending; classify 131047 on both paths; undelivered query catches silent cases. |
| Status values | `sent`, `delivered`, `read`, `failed`, `played` (voice). Pricing is per message (`regular`, `free_customer_service`, `free_entry_point`). From v24.0 the `conversation` object is gone. | H | `played` recorded as ignored; pricing is not needed. |
| Customer identity | Since ~April 2026 every webhook carries a business-scoped user id (`contacts[].user_id`, `messages[].from_user_id`, `statuses[].recipient_user_id`, e.g. `IN.…`). The phone number (`from`, `wa_id`, `recipient_id`) can be absent for users with usernames. Since July 2026 a message can be sent to a user id via `recipient`; if both are given, the phone number wins. | H | Customers are keyed by user id when present, phone optional; sends use `to` when a number is known, else `recipient`. |
| Rate limits | Default 80 msg/s per number; to one user about 1 message per 6 s with short bursts. No `Retry-After` header is documented. For 131056 Meta suggests waiting 4^X seconds. | H/M | Classified retry with our own backoff; never burst-test one tester. |
| Graph API version | Latest is v26.0 (2026-07-29). v21.0, which V1 pinned, expires 2027-01-21. | H | Default to v26.0. |
| Templates | Utility templates are free inside an open service window; business verification is not required (new accounts limited to 250 unique users/24h). Whether a payment method is needed is not stated; 131042 covers missing billing. | M | Template fallback stays behind Gate C. |

## Error codes

Meta now says to branch on `code` (plus `error_data.details`), not HTTP status, and
that `title` will be deprecated. 131030 (recipient not in test allow-list) is no longer
on the error page but V1 received it. 131064 is new. The taxonomy V2 uses is in
`app/services/whatsapp/error_classifier.rb`; codes V1 actually received are marked there.

## Catalog API (for Phase 12)

- Push with `POST /{catalog_id}/items_batch` (`item_type=PRODUCT_ITEM`, `allow_upsert`
  defaults to true, `requests` JSON-encoded): `UPDATE` with the same field names and
  price format as the CSV feed (`"15.50 USD"`), `DELETE` with only an id. The older
  `/batch` endpoint is deprecated for new integrations. Up to 5000 requests per call.
- A 200 only means "queued". Poll `GET /{catalog_id}/check_batch_request_status?handle=…`;
  only `finished` is documented, with per-item errors and warnings.
- Read back with `GET /{catalog_id}/products?fields=retailer_id,name,price,availability,…`.
  Field names differ from the push side (`retailer_id`/`name`/`url` vs `id`/`title`/`link`),
  and the returned price format is undocumented, so it is parsed defensively.
- `preorder` is not a documented batch availability value. New/changed items pass a
  commerce review (`review_status`). No propagation latency to WhatsApp is documented.
- A scheduled feed overwrites API edits on its next run; harmless when both come from
  the same database, but the feed schedule should be off once API sync is verified.
- Needs `catalog_management` (and `business_management`); a business using its own app
  should not need App Review (medium confidence).
