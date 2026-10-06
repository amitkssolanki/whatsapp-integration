require "rails_helper"

RSpec.describe "Admin health", type: :request do
  include_context "admin operator"

  let(:customer) { create_customer(number: "15550001234", name: "Jordan Rivera") }

  def outbound(status, **attrs) = create_outbound(status: status, customer: customer, **attrs)

  def delivery(status, **attrs)
    body = '{"object":"whatsapp_business_account","entry":[]}'
    create_delivery(status: status, body: body, signature_header: sign(body), **attrs)
  end

  def jobs(klass) = enqueued_jobs.select { |job| job["job_class"] == klass }

  it "is the admin landing page and the first nav item" do
    get "/admin"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<h1>Health</h1>")
    expect(response.body.index(">Health<")).to be < response.body.index(">Orders<")
    expect(response.body).to include('http-equiv="refresh"')
    expect(admin_health_path).to eq("/admin/health")
  end

  it "renders calmly on an empty database" do
    get "/admin/health"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("No failed messages.", "failed jobs", "never")
    expect(response.body).not_to include("banner-bad")
  end

  context "with a full set of problems" do
    before do
      delivery(:failed, last_error_class: "RuntimeError")
      delivery(:partially_failed)
      delivery(:unparseable)
      delivery(:ignored)
      delivery(:processed, outcome: { "summary" => { "orphan" => 2, "anomaly" => 1 }, "items" => [] })

      outbound(:failed, error_category: "auth_config", error_code: 190, error_title: "Token expired", failed_at: 5.minutes.ago)
      outbound(:failed, error_category: "request_invalid", error_code: 100, error_title: "Bad", failed_at: 5.minutes.ago)
      outbound(:unknown)
      outbound(:accepted, accepted_at: 30.minutes.ago)
      outbound(:blocked, blocked_at: 2.minutes.ago, error_category: "window_closed")
      outbound(:retry_scheduled, next_attempt_at: 3.minutes.from_now, attempts: 2, error_category: "transient_platform")
      create_order(customer: customer, review_status: :needs_review, total_cents: 2150)
      job = SolidQueue::Job.create!(queue_name: "default", class_name: "SendMessageJob", arguments: "{}")
      SolidQueue::FailedExecution.create!(job: job, error: "boom")
    end

    it "shows every section with counts and links to the records" do
      get "/admin/health"
      body = response.body

      expect(body).to include("Webhook deliveries", "Outbound messages by status", "Failed sends by category", "Unknown outcome", "Undelivered over 10 minutes",
                              "Blocked by the 24h window", "Retry scheduled", "Orders needing review", "Orphans and anomalies", "Background jobs", "Catalog sync")
      expect(body).to include("RuntimeError", "Unparseable (7d): <strong>1", "Ignored (7d): <strong>1", "Orphan statuses: <strong>2", "Anomalies: <strong>1")
      expect(body).to include("next attempt", "attempt 2", "outcome unknown", "$21.50", "failed jobs")
      expect(body).to include("href=\"/admin/deliveries/#{WebhookDelivery.failed.first.id}\"")
      expect(body).to include("href=\"/admin/orders/#{Order.first.id}\"")
      expect(body).to include("href=\"/admin/conversations/#{customer.conversation.id}#message-#{Message.unknown.first.id}\"")
      expect(body).to include("auth_config", "request_invalid")
    end

    it "offers a Replay button per failed delivery and a bulk replay" do
      get "/admin/health"

      expect(response.body.scan(">Replay<").size).to be >= 2
      expect(response.body).to include("Replay all failed")
    end

    it "offers a bulk resend only for resendable categories" do
      get "/admin/health"

      expect(response.body).to include("Resend all failed in auth_config")
      expect(response.body).not_to include("Resend all failed in request_invalid")
      expect(response.body).to include("resending would fail the same way")
    end

    it "shows the red configuration banner when only config errors are failing" do
      Message.where(error_category: "request_invalid").delete_all

      get "/admin/health"

      expect(response.body).to include("banner-bad", "Sending is failing because of configuration", "auth_config", "code 190: Token expired")
    end

    it "does not show the banner when another kind of failure is mixed in" do
      get "/admin/health"

      expect(response.body).not_to include("banner-bad")
    end
  end

  describe "catalog section" do
    it "shows the last runs, dirty and drift counts, the drift list and failing products" do
      products = create_menu
      products.first.update_columns(catalog_sync_error: "image_link is invalid")
      CatalogSyncRun.create!(kind: "push", status: "failed", created_at: 1.hour.ago, error_message: "rate_limited: slow down")
      CatalogSyncRun.create!(kind: "reconcile", status: "succeeded", created_at: 2.hours.ago, finished_at: 2.hours.ago,
                             result: { drift: [ { type: "price_mismatch", sku: "MAI-006", local: "15.50 USD", remote: "14.00 USD" },
                                                { type: "missing_remote", sku: "BEV-001" },
                                                { type: "name_mismatch", sku: "DES-003", pending_push: true } ] })

      get "/admin/health"

      expect(response.body).to include("failed", "rate_limited: slow down", "succeeded", "Unsynced products", "3")
      expect(response.body).to include("MAI-006", "price mismatch", "14.00 USD", "missing remote", "waiting on a push")
      expect(response.body).not_to include("name mismatch")
      expect(response.body).to include("Failing products (1)", "image_link is invalid", "Sync now", "Reconcile now", "sync disabled")
    end

    it "hides the disabled note when sync is on" do
      Rails.application.config.whatsapp.catalog_sync_enabled = true

      get "/admin/health"

      expect(response.body).not_to include("sync disabled")
    ensure
      Rails.application.config.whatsapp.catalog_sync_enabled = false
    end
  end

  describe "Sync now" do
    it "refuses with the reason while sync is disabled" do
      post "/admin/catalog/sync_now"
      follow_redirect!

      expect(response.body).to include("Not done: catalog sync is disabled")
      expect(jobs("CatalogPushJob")).to be_empty
    end

    it "queues a push as the operator when enabled" do
      Rails.application.config.whatsapp.catalog_sync_enabled = true

      post "/admin/catalog/sync_now"

      expect(response).to redirect_to("/admin/health")
      expect(jobs("CatalogPushJob").first["arguments"].last).to include("triggered_by" => AdminAuth::ADMIN_USER)
      follow_redirect!
      expect(response.body).to include("Catalog push queued")
    ensure
      Rails.application.config.whatsapp.catalog_sync_enabled = false
    end
  end

  describe "Reconcile now" do
    it "queues a read-only reconcile as the operator" do
      post "/admin/catalog/reconcile_now"

      expect(response).to redirect_to("/admin/health")
      expect(jobs("CatalogReconcileJob").first["arguments"].last).to include("by" => AdminAuth::ADMIN_USER)
      follow_redirect!
      expect(response.body).to include("Catalog reconcile queued")
    end

    it "flashes a refusal when the job cannot be queued" do
      allow(CatalogReconcileJob).to receive(:perform_later).and_return(false)

      post "/admin/catalog/reconcile_now"
      follow_redirect!

      expect(response.body).to include("Not done:")
    end
  end

  describe "Resend all failed in a category" do
    def send_jobs = jobs("SendMessageJob")

    it "resends every failed message of the category as the operator" do
      outbound(:failed, error_category: "auth_config", failed_at: 1.minute.ago)
      outbound(:failed, error_category: "auth_config", failed_at: 1.minute.ago)
      other = outbound(:failed, error_category: "account_config", failed_at: 1.minute.ago)

      log = capture_log { post "/admin/messages/resend_failed", params: { category: "auth_config" } }

      expect(response).to redirect_to("/admin/health")
      expect(send_jobs.size).to eq(2)
      expect(other.reload).to be_failed
      expect(log).to include("event=message.resend_bulk").and include("by=#{AdminAuth::ADMIN_USER}")
      follow_redirect!
      expect(response.body).to include("2 failed messages (auth_config) queued to send again")
    end

    it "refuses a category that cannot be resent" do
      outbound(:failed, error_category: "request_invalid", failed_at: 1.minute.ago)

      post "/admin/messages/resend_failed", params: { category: "request_invalid" }
      follow_redirect!

      expect(response.body).to include("Not done:", "not a resendable category")
      expect(send_jobs).to be_empty
    end
  end

  describe "Replay all failed from the health page" do
    it "replays and returns to the health page when that is where the click came from" do
      delivery(:failed)

      post "/admin/deliveries/replay_failed", headers: { "HTTP_REFERER" => "http://www.example.com/admin/health" }

      expect(response).to redirect_to("http://www.example.com/admin/health")
      expect(jobs("ProcessWebhookDeliveryJob").size).to eq(1)
    end
  end

  describe "PII masking" do
    it "shows no customer data (the page links records by our ids only)" do
      Rails.application.config.whatsapp.mask_pii = true
      outbound(:unknown)

      get "/admin/health"

      expect(response.body).not_to include("Jordan", "15550001234")
      expect(response.body).to include("PII masked")
    end
  end
end
