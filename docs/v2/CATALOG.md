# Catalog sync (Phase 12)

How product changes reach the WhatsApp Catalog, what has and has not been
verified, and how to fall back to the CSV feed.

## Decision

**API push plus a read-only reconcile, with the CSV feed kept as the fallback (Gate B).**

- The app database is the source of truth. Meta's `retailer_id` is `Product#sku`.
- A product edit that changes a Meta-visible field enqueues a push (30s debounce).
  `CatalogPushJob` sends every dirty product in one `items_batch` call;
  `CatalogBatchStatusJob` confirms the outcome.
- `CatalogReconcileJob` runs daily at 03:00 (server time zone) and records how Meta
  differs from the database. It never corrects anything.
- `GET /catalog/feed.csv` (`Catalog::FeedGenerator`) is unchanged and keeps working.
- Everything is off unless `CATALOG_SYNC_ENABLED=true`.

## How it works

| Piece | Role |
|---|---|
| `Catalog::Fields` | Product to `items_batch` `data`; `digest` = SHA256 of the canonical (sorted-key) JSON |
| `Product#catalog_digest`, `Product.catalog_dirty` | Dirty = digest differs from `catalog_synced_digest`, or never synced |
| `Catalog::Client` | Faraday (open 3s, read 15s). `items_batch`, `batch_status`, `products`. Returns result objects, never raises |
| `CatalogPushJob` | Builds one UPDATE batch (max 5000), creates a `catalog_sync_runs` row, stores the handle |
| `CatalogBatchStatusJob` | Polls; on `finished` marks products synced at the digest that was **sent** |
| `CatalogReconcileJob` + `Catalog::Reconciler` + `Catalog::PriceParser` | Read-back and diff |
| `Catalog::SyncNow.call(by:, full: false)` | Operator "Sync now": immediate push |
| `Catalog::Status.call` | `last_push_run`, `last_reconcile_run`, `dirty_count`, `drift_count`, `failing_products` for the UI |

Push run lifecycle: `queued` then `submitted` then `succeeded`, `partially_failed` or `failed`.
Reconcile runs end `succeeded` (drift is a result, not a failure) or `failed` (could not read).

Guarantees worth knowing:

- **Sent digest, not current digest.** A product edited while its batch is in flight is
  marked synced at the old digest, so it stays dirty and is pushed again.
- **Idempotent.** Duplicate enqueues push nothing new: only dirty products are sent, and
  a product already carried by an in-flight batch with the same digest (runs younger than
  1 hour) is skipped.
- **Retries.** A push that fails with a retryable category (`transient`: timeout, connection,
  5xx; `rate_limited`) is retried on the same run after 1 min and 5 min: 3 attempts in
  all, then `failed`. Auth, permission, config and invalid-request failures fail at once.
  Polling uses 10s, 30s, 1m, 2m, 5m, 5m, 5m between 8 polls, then fails with
  "timed out waiting for Meta". A failed run leaves its products dirty with
  `catalog_sync_error` set. The next edit or "Sync now" starts a new run.
- **Unattributable errors mark nothing synced.** If Meta reports errors that name no
  retailer id we sent, the run fails and no product is marked synced.
- **Rejected items stay dirty** with their error in `catalog_sync_error`, and are re-sent by
  the next push (so a permanently invalid item is retried on every later push; fix the
  data, which clears it).
- **Bookkeeping writes use `update_all`/`update_columns`**, so they never retrigger a push.
- `catalog_sync_runs.requested_items` is `{sku => digest sent}` (the column's `[]` default
  is never used for push runs).

## Field mapping

Same names and formats as the CSV feed, with the differences marked.

| Batch field | From | Notes |
|---|---|---|
| `id` | `sku` | = `retailer_id`, what order webhooks carry |
| `title` | `name` | truncated to 100 characters |
| `description` | `description` | falls back to `name` when blank (Meta needs one) |
| `availability` | `availability` | `in stock` / `out of stock`; **`preorder` is sent as `out of stock`** |
| `condition` | constant `new` | |
| `price` | `price_cents`, `currency` | `"15.50 USD"` from integer cents, no floats |
| `link` | `APP_HOST` + `/products/:id` | `https://$APP_HOST`, else `http://localhost:3000`; changing `APP_HOST` makes every product dirty |
| `image_link` | `image_url` | omitted when blank |
| `brand` | constant `The Local Table` | |

Why `preorder` becomes `out of stock`: the docs do not list `preorder` as a batch
availability value. A rejected value would fail the item. "Out of stock" is the safe
reading (customers cannot add something we cannot fulfil now). The CSV feed still sends
`preorder`. Reconcile expects `out of stock` for a preorder product.

Changing `sku` pushes a new item and leaves the old one on Meta (reported as `extra_remote`).

## Removal

There are no deletes. **Out of stock is the removal**: set the product to out of stock
and it stays in the catalog but cannot be ordered. Deleting a product row does not remove it
from Meta; it will show up as `extra_remote` in reconcile, and must be deleted in Commerce
Manager by an operator. This keeps order history (`retailer_id` on past orders) resolvable
and avoids a destructive API call driven by a database delete.

## Reconcile drift types

`missing_remote`, `extra_remote`, `price_mismatch`, `price_unparseable`,
`availability_mismatch`, `name_mismatch`, `review_not_approved` (any `review_status`
that is present and not `approved`; a missing one is ignored). Field drift on a product
with an unpushed local change is tagged `pending_push` and not counted by
`Catalog::Status#drift_count`. Reconcile never enqueues a push and never edits a product.

`Catalog::PriceParser` accepts `15.50 USD`, `USD 15.50`, `USD15.50`, `$15.50`, `1,550.00`,
`15,50 EUR`, minor-unit integers and digit strings (with the `currency` field), and
returns nil for anything ambiguous or finer than a cent (reported as `price_unparseable`).
A digit string without a decimal point or currency marker is read as **minor units**, which
is a guess until the live read-back confirms the format.

## Verified only against documentation (no live calls)

All of this was built and tested without touching Meta. The specs use Faraday's in-memory
test adapter only. Verified against docs and nothing else:

- `POST /{catalog_id}/items_batch`: `item_type=PRODUCT_ITEM`, `allow_upsert`, JSON `requests`,
  `UPDATE` entries with feed-style field names, 5000 request cap.
- `GET /{catalog_id}/check_batch_request_status?handle=...` with only `finished` documented.
- `GET /{catalog_id}/products` field names (`retailer_id`, `name`, ...) and the `filter` syntax.
- Error handling by `code` (rate-limit codes 4/17/32/613/80004/130429, auth 102/190, permission 10/200-299).

Assumed, not documented: the exact shape of `validation_status`, of status `errors`
(`id`/`retailer_id`/`message`) and `ids_of_invalid_requests` (strings are treated as retailer ids;
integers are treated as unattributable), the paging envelope, the `review_status` values,
and that a non-`finished` status string means "keep waiting".

## Live checks still required (do these once, with a test catalog)

1. **Price format returned by read-back.** Run `CatalogReconcileJob.perform_now(by: "console")`
   after one push and inspect the `price`/`currency` in the raw response. If `price_unparseable`
   appears, only `Catalog::PriceParser` and its spec need to change.
2. **Preorder mapping.** Push a preorder product and confirm Meta accepts `out of stock` and
   shows it as out of stock (and whether `available for order` would be accepted and better).
3. **Review latency and statuses.** Time from `finished` to `review_status: approved`, whether
   WhatsApp serves the item before approval, and the real `review_status` strings.
4. **Permission.** The system-user token needs `catalog_management` (and `business_management`);
   confirm `items_batch` and `products` succeed with it, and whether App Review is needed
   for a business using its own app.
5. **Batch status and error shapes.** Push a deliberately invalid item (blank price) and read
   the status response; confirm errors carry a retailer id (otherwise the run fails as
   unattributable) and see the real `status` values besides `finished`.
6. **Propagation to WhatsApp.** How long after approval an edit appears in the in-chat catalog.
7. **Feed interplay.** A scheduled feed overwrites API edits on its next run; confirm the feed
   schedule is off (or identical, since both come from this database) before relying on the API.

## Fallback switch (Gate B)

If any live check fails and cannot be fixed quickly:

1. Set `CATALOG_SYNC_ENABLED=false` (or unset it; default is off) and restart the app. Edits
   no longer enqueue pushes, "Sync now" reports that sync is disabled, and the scheduled
   reconcile does nothing. In-flight status jobs finish harmlessly.
2. In Commerce Manager, set the catalog's data source to the scheduled feed pointing at
   `https://<APP_HOST>/catalog/feed.csv` (daily or hourly). **Only Amit operates Commerce
   Manager**; no automation touches it.
3. Nothing in the app changes: the feed code path is untouched by this work.

To go back to the API: turn the feed schedule off in Commerce Manager first, set
`CATALOG_SYNC_ENABLED=true`, run "Sync now" with a full push (`Catalog::SyncNow.call(by: "...", full: true)`),
then run a reconcile and check it is clean.

## Configuration

| Variable | Meaning |
|---|---|
| `CATALOG_SYNC_ENABLED` | `true` to enable push and scheduled reconcile. Default off |
| `CATALOG_ID` | Target catalog (required for any API call) |
| `WHATSAPP_TOKEN` | Token with `catalog_management` |
| `WHATSAPP_API_VERSION` | Graph version in request paths |
| `APP_HOST` | Public host used in item `link`s |
