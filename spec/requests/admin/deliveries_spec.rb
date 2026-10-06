require "rails_helper"

RSpec.describe "Admin deliveries", type: :request do
  include_context "admin operator"

  let(:wamid) { "wamid.HBgLMTU1NTAwMDEyMzQVAgASGBQzQTAxQUJDREVGMTIz" }
  let(:body) { %({"object":"whatsapp_business_account","entry":[{"changes":[{"value":{"messages":[{"from":"15550001234","id":"#{wamid}","text":{"body":"secret order text"}}]}}]}]}) }

  def delivery(status = :processed, **attrs)
    create_delivery(status: status, body: body, signature_header: sign(body), **attrs)
  end

  def replay_jobs = enqueued_jobs.select { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }

  describe "index" do
    it "lists newest first with status, item counts and outcome summary" do
      older = delivery(:processed, received_at: 2.hours.ago, item_counts: { "messages" => 1 }, outcome: { "summary" => { "applied" => 1 } })
      newer = delivery(:failed, received_at: 1.hour.ago, item_counts: { "statuses" => 2 }, attempts: 3, last_error_class: "RuntimeError")

      get "/admin/deliveries"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("##{newer.id}<")).to be < body.index("##{older.id}<")
      expect(body).to include("1 messages", "2 statuses", "applied 1", "RuntimeError", "badge-bad", 'http-equiv="refresh"')
    end

    it "filters by status and ignores an unknown filter" do
      delivery(:processed)
      delivery(:failed)
      delivery(:unparseable)

      get "/admin/deliveries", params: { status: "failed" }
      expect(response.body.scan(/<td>#\d+<\/td>/).size).to eq(1)
      expect(response.body).to include("Failed (1)", "Processed (1)", "All (3)")

      get "/admin/deliveries", params: { status: "nope" }
      expect(response.body.scan(/<td>#\d+<\/td>/).size).to eq(3)
    end

    it "offers Replay only for replayable deliveries and a bulk replay when something failed" do
      delivery(:unparseable)
      get "/admin/deliveries"
      expect(response.body).not_to include(">Replay<", "Replay all failed")

      delivery(:partially_failed)
      get "/admin/deliveries"
      expect(response.body).to include(">Replay<", "Replay all failed (1)")
    end

    it "hides Replay for a purged delivery and says it is purged" do
      create_delivery(status: :failed, raw_body: "", purged_at: Time.utc(2026, 12, 2))

      get "/admin/deliveries"

      expect(response.body).not_to include(">Replay<")
      expect(response.body).to include("purged")
    end

    it "never loads or renders the raw body" do
      delivery

      get "/admin/deliveries"

      expect(response.body).not_to include("secret order text", "15550001234", "wamid.", "raw_body")
    end
  end

  describe "show" do
    it "shows the audit fields, error and item results with Meta ids masked to six characters" do
      d = delivery(:partially_failed,
                   attempts: 2, replay_count: 1, last_replayed_at: 1.minute.ago, last_replayed_by: "amit",
                   last_error_class: "RuntimeError", last_error_message: "boom for #{wamid}",
                   item_counts: { "messages" => 1, "statuses" => 1 },
                   outcome: { "summary" => { "applied" => 1, "orphan" => 1 },
                              "items" => [ { "kind" => "message", "ref" => wamid, "result" => "applied", "detail" => "message_id=4" },
                                           { "kind" => "status", "ref" => wamid, "result" => "orphan", "detail" => "no outbound message matches" } ] })

      get "/admin/deliveries/#{d.id}"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body).to include("Delivery ##{d.id}", "applied 1 · orphan 1", "1 messages, 1 statuses", "by amit", "RuntimeError", "[id]",
                              "…#{wamid.last(6)}", "no outbound message matches", "message_id=4")
      expect(body).not_to include(wamid, "wamid.", "secret order text", "15550001234")
      expect(body).to include("Replay this delivery")
    end

    it "shows a delivery that has no items" do
      d = delivery(:ignored, outcome: { "summary" => {}, "items" => [], "reason" => "object_not_whatsapp" })

      get "/admin/deliveries/#{d.id}"

      expect(response.body).to include("No items were processed", "object_not_whatsapp")
      expect(response.body).not_to include("Replay this delivery")
    end

    it "shows when the body was purged and offers no Replay on the detail page" do
      d = delivery(:failed, raw_body: "", purged_at: Time.utc(2026, 12, 2, 9, 30))

      get "/admin/deliveries/#{d.id}"

      expect(response.body).to include("purged", "cannot be replayed")
      expect(response.body).not_to include("Replay this delivery")
    end

    it "cannot reach the raw body or its base64 twin even by accident" do
      d = delivery

      loaded = WebhookDelivery.select(Admin::DeliveriesController::SAFE_COLUMNS).find(d.id)
      expect { loaded.raw_body }.to raise_error(ActiveModel::MissingAttributeError)
      expect { loaded.raw_body_base64 }.to raise_error(ActiveModel::MissingAttributeError)
      expect(Admin::DeliveriesController::SAFE_COLUMNS).not_to include("raw_body", "raw_body_base64")
    end

    it "never selects the body columns for the list, the detail page or Health (review 2 #10b)" do
      body = meta_fixture("order")
      d = delivery(:failed, raw_body_base64: Base64.strict_encode64(body))
      queries = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

      [ "/admin/deliveries", "/admin/deliveries/#{d.id}", "/admin/health" ].each { |path| get path }
      ActiveSupport::Notifications.unsubscribe(subscriber)

      delivery_selects = queries.select { |sql| sql =~ /FROM "webhook_deliveries"/ && sql.start_with?("SELECT") && !sql.include?("COUNT(") }
      expect(delivery_selects).not_to be_empty
      delivery_selects.each do |sql|
        expect(sql).not_to include("raw_body"), sql
        expect(sql).not_to match(/"webhook_deliveries"\.\*/), sql
      end
    end

    it "404s for a missing delivery" do
      get "/admin/deliveries/0"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "replay" do
    it "replays as the signed-in operator" do
      d = delivery(:failed)

      post "/admin/deliveries/#{d.id}/replay"

      expect(response).to redirect_to("/admin/deliveries/#{d.id}")
      expect(d.reload).to have_attributes(status: "processing", replay_count: 1, last_replayed_by: AdminAuth::ADMIN_USER)
      expect(replay_jobs.size).to eq(1)
      follow_redirect!
      expect(response.body).to include("queued for replay")
    end

    it "flashes the purge reason when a purged delivery is replayed anyway" do
      d = delivery(:failed, raw_body: "", purged_at: Time.utc(2026, 12, 2))

      post "/admin/deliveries/#{d.id}/replay"
      follow_redirect!

      expect(response.body).to include("Not done:", "raw body was purged on 2026-12-02")
      expect(replay_jobs).to be_empty
    end

    it "refuses a synthetic delivery with a flash, and does not enqueue anything" do
      d = delivery(:failed, synthetic: true)

      post "/admin/deliveries/#{d.id}/replay"
      follow_redirect!

      expect(response.body).to include("Not done:", "synthetic (demo) delivery cannot be replayed")
      expect(d.reload).to be_failed
      expect(replay_jobs).to be_empty
    end

    it "hides Replay for synthetic deliveries, in the list, on the page and in the bulk button" do
      synthetic = delivery(:failed, synthetic: true)

      get "/admin/deliveries"
      expect(response.body).not_to include(">Replay<", "Replay all failed", replay_admin_delivery_path(synthetic))
      expect(response.body).not_to match(/value="Replay"/)

      get "/admin/deliveries/#{synthetic.id}"
      expect(response.body).not_to include("Replay this delivery")

      real = delivery(:failed)
      get "/admin/deliveries"
      expect(response.body).to include("Replay all failed (1)", replay_admin_delivery_path(real))
    end

    it "skips synthetic deliveries in the bulk replay" do
      real = delivery(:failed)
      synthetic = delivery(:partially_failed, synthetic: true)

      post "/admin/deliveries/replay_failed"

      expect(real.reload).to be_processing
      expect(synthetic.reload).to be_partially_failed
      expect(replay_jobs.size).to eq(1)
    end

    it "skips purged deliveries in the bulk replay" do
      kept = delivery(:failed)
      purged = delivery(:failed, raw_body: "", purged_at: Time.utc(2026, 12, 2))

      post "/admin/deliveries/replay_failed"

      expect(kept.reload).to be_processing
      expect(purged.reload).to be_failed
    end

    it "flashes the refusal for a delivery that cannot be replayed" do
      d = delivery(:unparseable)

      post "/admin/deliveries/#{d.id}/replay"
      follow_redirect!

      expect(response.body).to include("Not done:", "a unparseable delivery cannot be replayed")
      expect(replay_jobs).to be_empty
    end

    it "flashes the refusal when the stored signature no longer matches" do
      d = delivery(:failed, signature_header: "sha256=#{'0' * 64}")

      post "/admin/deliveries/#{d.id}/replay"
      follow_redirect!

      expect(response.body).to include("does not match its stored signature")
      expect(d.reload).to be_failed
    end

    it "flashes a failed enqueue" do
      d = delivery(:failed)
      allow(ProcessWebhookDeliveryJob).to receive(:perform_later).and_return(false)

      post "/admin/deliveries/#{d.id}/replay"
      follow_redirect!

      expect(response.body).to include("Not done:")
      expect(d.reload).to be_failed
    end
  end

  describe "replay_failed" do
    it "replays every failed and partially failed delivery and leaves the rest" do
      failed = delivery(:failed)
      partial = delivery(:partially_failed)
      done = delivery(:processed)

      post "/admin/deliveries/replay_failed"

      expect(response).to redirect_to("/admin/deliveries")
      expect([ failed, partial ].map { |d| d.reload.last_replayed_by }).to all(eq(AdminAuth::ADMIN_USER))
      expect(done.reload).to be_processed
      expect(replay_jobs.size).to eq(2)
      follow_redirect!
      expect(response.body).to include("2 deliveries queued for replay")
    end

    it "reports the ones it could not replay" do
      delivery(:failed)
      delivery(:failed, signature_header: "sha256=#{'0' * 64}")

      post "/admin/deliveries/replay_failed"
      follow_redirect!

      expect(response.body).to include("1 delivery queued for replay", "Not replayed:", "stored signature")
    end
  end

  describe "PII masking" do
    it "shows nothing about the customer even unmasked, and the footer flag when masked" do
      Rails.application.config.whatsapp.mask_pii = true
      d = delivery

      get "/admin/deliveries/#{d.id}"

      expect(response.body).to include("PII masked")
      expect(response.body).not_to include("15550001234", "secret order text")
    end
  end
end
