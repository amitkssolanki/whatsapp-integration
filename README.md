# The Local Table — WhatsApp Native Catalog demo

A Rails app demonstrating a WhatsApp shopping experience using Meta's
**native Catalog + Cart** UI: customers message a WhatsApp number, tap the
catalog icon to browse a real menu (20 real dishes, real photos), add items
to WhatsApp's built-in cart, and tap **Send** — which lands here as an
`order` webhook, gets recorded, and triggers a confirmation reply.

This is a second front door onto the same "store assistant" idea as the
voice agent receptionist — WhatsApp's native cart replaces the conversational
product-lookup role an MCP-backed agent plays on a phone call, so this app
doesn't run an LLM; it's a feed + webhook integration.

## What's here

- `GET /catalog/feed.csv` — the product feed Meta Commerce Manager polls
  ([`Catalog::FeedGenerator`](app/services/catalog/feed_generator.rb)).
- `GET/POST /webhooks/whatsapp` — webhook verification handshake + inbound
  message handling ([`Webhooks::WhatsappController`](app/controllers/webhooks/whatsapp_controller.rb),
  [`Webhooks::WhatsappMessageProcessor`](app/services/webhooks/whatsapp_message_processor.rb)).
- `/` — public menu page (also the feed's per-product `link` target).
- `/admin/conversations`, `/admin/orders`, `/admin/products` — plain,
  unauthenticated views to watch the demo happen live. **Do not deploy this
  as-is** — the admin section and the webhook's optional signature bypass
  have no auth; add both before this touches the public internet for real.

## Local setup

```bash
bundle install
bin/rails db:setup   # creates + migrates + seeds the DB
bin/rails server
```

Visit `http://localhost:3000` for the public menu, `http://localhost:3000/admin/orders`
for the admin view.

Copy `.env.example` to `.env` and fill in values as you complete the Meta
setup below — `dotenv-rails` loads it automatically in development.

## Meta / WhatsApp setup (do this once, in your browser)

You'll need a Meta developer account and a Business Portfolio. None of this
can be done from the Rails app — it's all in Meta's dashboards.

1. **Create the app.** [developers.facebook.com](https://developers.facebook.com) →
   *My Apps* → *Create App* → type **Business**. Add the **WhatsApp** product
   from the dashboard sidebar. This gives you a free test phone number and a
   temporary (24h) access token under *WhatsApp → API Setup* — enough to
   test steps 3–6 immediately.

2. **Get a permanent token.** Temporary tokens expire in 24h, which is
   annoying mid-demo. Business Settings → *Users → System Users* → create
   one → *Add Assets* (assign your app) → *Generate New Token* → check
   `whatsapp_business_messaging` (and `catalog_management` if you'll manage
   the catalog via API later). Put this in `WHATSAPP_TOKEN`.

3. **Expose your local server.** Meta needs a public HTTPS URL to reach your
   webhook:
   ```bash
   ngrok http 3000
   ```
   Copy the `https://…ngrok-free.app` URL it prints.

4. **Configure the webhook.** WhatsApp → *Configuration* → *Webhook* → Edit:
   - Callback URL: `https://<ngrok-domain>/webhooks/whatsapp`
   - Verify token: any string you pick — put the same string in `.env` as
     `WHATSAPP_VERIFY_TOKEN` *before* clicking Verify and Save (this app must
     already be running for the handshake to succeed).
   - Subscribe to the `messages` webhook field.

5. **Create the catalog.** [Commerce Manager](https://business.facebook.com/commerce/) →
   *Add Catalog* → type **E-commerce** (Food/Restaurant catalogs also work) →
   name it "The Local Table". Inside the catalog: *Data Sources → Add Items →
   Data Feed* → paste `https://<ngrok-domain>/catalog/feed.csv` → schedule
   (daily is fine) → after it's created, open it and click **Update now** to
   force an immediate sync rather than waiting.

6. **Connect the catalog to WhatsApp.** [WhatsApp Manager](https://business.facebook.com/wa/manage/) →
   your Business Account → *Account tools → Catalog* → connect the catalog
   you just made. Then under your phone number's settings, make sure
   **Cart** is enabled.

7. **Test it.** From your own phone, message the test number (WhatsApp →
   API Setup shows it, and you must first add your number as an allowed
   test recipient there). Tap the catalog icon in the chat, browse, add a
   couple of items, tap **View cart → Send**. Watch:
   - The order land in `bin/rails console` logs / `/admin/orders`.
   - A confirmation text arrive back in WhatsApp.
   - A plain "hi" get a catalog-message reply instead.

## Verifying without a live Meta connection

You don't need any of the above to check the app logic itself:

```bash
# Feed renders
curl localhost:3000/catalog/feed.csv

# Verification handshake
curl 'localhost:3000/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=YOUR_TOKEN&hub.challenge=123'
# => should return "123"

# Run the test suite (includes a fixture WhatsApp `order` webhook payload)
bundle exec rspec
```

## Notes on the demo data

Seed data (`db/seeds.rb`) is a 20-item menu across Starters/Mains/Desserts/
Beverages. Names and photos are real, sourced from the free
[TheMealDB](https://www.themealdb.com/api.php) and
[TheCocktailDB](https://www.thecocktaildb.com/api.php) public APIs — "The
Local Table" itself is a fictional restaurant built for this demo.
