require "rails_helper"

RSpec.describe "Admin orders", type: :request do
  include_context "admin operator"

  let!(:products) { create_menu }
  let(:customer) { create_customer(number: "15550001234", name: "Jordan Rivera") }

  def build_order(status: :received, customer: self.customer, review: :clear, issues: [], note: nil, **attrs)
    create_order(status: status, customer: customer, review_status: review, validation_issues: issues, wa_order_note: note, total_cents: 1700, **attrs).tap do |order|
      order.order_items.create!(product: products[0], product_retailer_id: "MAI-006", quantity: 1, item_price_cents: 1250, catalog_price_cents: 1550)
      order.order_items.create!(product: products[1], product_retailer_id: "BEV-001", quantity: 1, item_price_cents: 450, catalog_price_cents: 450)
    end
  end

  def send_jobs = enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }

  describe "index" do
    it "lists orders with items, total, review flag, status and the latest notification" do
      order = build_order(review: :needs_review)
      create_outbound(customer: customer, order: order, status: :delivered, purpose: "order_received")
      create_outbound(customer: customer, order: order, status: :blocked, purpose: "order_accepted")

      get "/admin/orders"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Orders", "Jordan Rivera", "+15550001234", "$17.00", "needs review", "received")
      expect(response.body).to include("blocked: 24h window").and include("order accepted")
      expect(response.body).to include('http-equiv="refresh"')
    end

    it "filters by status and by needs review, with counts" do
      build_order(review: :needs_review)
      build_order(status: :accepted)
      build_order(status: :rejected)

      get "/admin/orders", params: { filter: "needs_review" }
      expect(response.body).to include("Needs review (1)", "All (3)", "Accepted (1)", "Rejected (1)", "Received (1)")
      expect(response.body.scan(/<td>#\d+<\/td>/).size).to eq(1)

      get "/admin/orders", params: { filter: "accepted" }
      expect(response.body.scan(/<td>#\d+<\/td>/).size).to eq(1)
      expect(response.body).to include("badge-ok")

      get "/admin/orders", params: { filter: "bogus" }
      expect(response.body.scan(/<td>#\d+<\/td>/).size).to eq(3)
    end

    it "does not count a decided order as needing review" do
      build_order(status: :accepted, review: :needs_review)

      get "/admin/orders", params: { filter: "needs_review" }

      expect(response.body).to include("No orders here.")
    end

    it "can disable the refresh with live=0" do
      get "/admin/orders", params: { live: "0" }

      expect(response.body).not_to include('http-equiv="refresh"')
      expect(response.body).to include("refresh paused")
    end
  end

  describe "show" do
    it "highlights lines where the customer's price differs from the catalog price" do
      order = build_order(note: "no onions please")

      get "/admin/orders/#{order.id}"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.scan('<tr class="diff">').size).to eq(1)
      expect(body).to include("$12.50", "$15.50", "no onions please", "Item MAI-006")
    end

    it "explains every validation issue in words" do
      issues = [
        { "code" => "price_mismatch", "sku" => "MAI-006", "expected" => 1550, "actual" => 1250 },
        { "code" => "unknown_sku", "sku" => "ZZZ-1", "expected" => "a product in the catalog", "actual" => "ZZZ-1" },
        { "code" => "unavailable", "sku" => "DES-003", "expected" => "in_stock", "actual" => "out_of_stock" },
        { "code" => "invalid_quantity", "sku" => "BEV-001", "expected" => "integer >= 1", "actual" => "0" },
        { "code" => "invalid_price", "sku" => "BEV-001", "expected" => "non-negative decimal", "actual" => "abc" },
        { "code" => "currency_mismatch", "sku" => "BEV-001", "expected" => "USD", "actual" => "EUR" },
        { "code" => "unknown_catalog", "sku" => nil, "expected" => "111", "actual" => "222" },
        { "code" => "malformed", "sku" => nil, "expected" => "x", "actual" => 0 },
        { "code" => "brand_new_code", "sku" => nil, "expected" => 1, "actual" => 2 }
      ]
      order = build_order(review: :needs_review, issues: issues)

      get "/admin/orders/#{order.id}"

      expect(response.body).to include(
        "the customer saw $12.50 but our price is $15.50", "Unknown product ZZZ-1", "DES-003 is out of stock",
        "quantity &quot;0&quot; is not a whole number", "price &quot;abc&quot; is not a valid amount", "currency EUR differs from ours (USD)",
        "catalog 222, not the configured catalog (111)", "no usable product lines", "Brand new code: expected 1, got 2"
      )
    end

    it "shows every notification with its lifecycle, timestamps and error" do
      order = build_order
      create_outbound(customer: customer, order: order, status: :read, purpose: "order_received", accepted_at: 3.minutes.ago, sent_at: 3.minutes.ago,
                      delivered_at: 2.minutes.ago, read_at: 1.minute.ago)
      create_outbound(customer: customer, order: order, status: :failed, purpose: "order_accepted", error_category: "auth_config", error_title: "Token expired",
                      error_code: 190, error_details: "Session has expired", failed_at: 1.minute.ago)

      get "/admin/orders/#{order.id}"

      expect(response.body).to include("Customer notifications", "order received", "order accepted", "✓✓", "auth_config", "Token expired", "Session has expired")
    end

    it "shows the window badge and warns when the window is closed" do
      order = build_order
      open_window(customer.conversation, at: 30.hours.ago)

      get "/admin/orders/#{order.id}"

      expect(response.body).to include("window closed", "Customer will not be notified: 24h window closed")
    end

    it "shows no warning while the window is open" do
      order = build_order
      open_window(customer.conversation)

      get "/admin/orders/#{order.id}"

      expect(response.body).to include("window open")
      expect(response.body).not_to include("Customer will not be notified")
    end

    it "offers accept and reject only while the order is undecided, and says who decided otherwise" do
      order = build_order
      get "/admin/orders/#{order.id}"
      expect(response.body).to include("Accept order", "Reject order", "out_of_stock", "kitchen_closed", "cannot_fulfil", "other")

      order.accept!(by: "amit")
      get "/admin/orders/#{order.id}"
      expect(response.body).not_to include("Accept order")
      expect(response.body).to include("Accepted by <strong>amit</strong>")
    end

    it "404s for a missing order" do
      get "/admin/orders/0"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "accept" do
    it "accepts the order as the signed-in operator and queues the notification" do
      order = build_order

      expect { post "/admin/orders/#{order.id}/accept" }.to change { send_jobs.size }.by(1)

      expect(response).to redirect_to("/admin/orders/#{order.id}")
      expect(order.reload).to have_attributes(status: "accepted", decided_by: AdminAuth::ADMIN_USER)
      follow_redirect!
      expect(response.body).to include("Order ##{order.id} accepted")
    end

    it "flashes the reason when the order was already decided" do
      order = build_order
      order.reject!(by: "amit", reason: "other")

      expect { post "/admin/orders/#{order.id}/accept" }.not_to change { send_jobs.size }
      follow_redirect!

      expect(response.body).to include("Not done: order is already rejected")
      expect(order.reload).to be_rejected
    end
  end

  describe "reject" do
    it "stores the reason and the optional note, and records the operator" do
      order = build_order

      post "/admin/orders/#{order.id}/reject", params: { reason: "out_of_stock", note: "no lasagne left" }

      expect(order.reload).to have_attributes(status: "rejected", decided_by: AdminAuth::ADMIN_USER, rejection_reason: "out_of_stock: no lasagne left")
      expect(send_jobs.size).to eq(1)
      follow_redirect!
      expect(response.body).to include("rejected", "Out of stock: no lasagne left")
    end

    it "accepts a reason without a note" do
      order = build_order

      post "/admin/orders/#{order.id}/reject", params: { reason: "kitchen_closed", note: "  " }

      expect(order.reload.rejection_reason).to eq("kitchen_closed")
    end

    it "requires a known reason" do
      order = build_order

      [ {}, { reason: "" }, { reason: "because" } ].each do |params|
        post "/admin/orders/#{order.id}/reject", params: params
        follow_redirect!
        expect(response.body).to include("Choose a rejection reason")
      end
      expect(order.reload).to be_received
      expect(send_jobs).to be_empty
    end

    it "flashes the reason when the order is already decided" do
      order = build_order
      order.accept!(by: "amit")

      post "/admin/orders/#{order.id}/reject", params: { reason: "other" }
      follow_redirect!

      expect(response.body).to include("Not done: order is already accepted")
    end
  end

  describe "CSRF" do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    it "refuses a POST without an authenticity token even with valid credentials" do
      order = build_order

      post "/admin/orders/#{order.id}/accept"

      expect(response).to have_http_status(:unprocessable_content)
      expect(order.reload).to be_received
      expect(send_jobs).to be_empty
    end

    it "accepts a POST carrying the page's own token" do
      order = build_order
      get "/admin/orders/#{order.id}"
      token = response.body[/name="authenticity_token" value="([^"]+)"/, 1]

      post "/admin/orders/#{order.id}/accept", params: { authenticity_token: token }

      expect(order.reload).to be_accepted
    end
  end

  describe "PII masking" do
    before { Rails.application.config.whatsapp.mask_pii = true }

    it "hides the customer's name and number on the list and the detail page" do
      order = build_order(note: "hello")

      [ "/admin/orders", "/admin/orders/#{order.id}" ].each do |path|
        get path
        expect(response.body).not_to include("Jordan", "15550001234", "5550001"), path
        expect(response.body).to include("Customer ##{customer.id}", "+•• ••••• •1234", "PII masked"), path
      end
    end
  end
end
