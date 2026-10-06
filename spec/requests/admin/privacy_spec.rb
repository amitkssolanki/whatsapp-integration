require "rails_helper"

# Cross-cutting guarantees for every admin page, checked against a database full
# of the data that must never leak: Meta message ids (they embed phone numbers),
# raw webhook bodies, and (when DEMO_MASK_PII=1) names and phone numbers.
RSpec.describe "Admin privacy", type: :request do
  include_context "admin operator"

  let(:wamid) { "wamid.HBgLMTU1NTAwMDEyMzQVAgASGBQzQTAxQUJDREVGMTIz" }
  let(:phone) { "15550001234" }
  let(:name) { "Jordan Rivera" }
  let(:user_id) { "US.13491208655302741918" }
  let(:raw_body) do
    %({"object":"whatsapp_business_account","entry":[{"changes":[{"value":{"contacts":[{"profile":{"name":"#{name}"},"wa_id":"#{phone}"}],) +
      %("messages":[{"from":"#{phone}","id":"#{wamid}","text":{"body":"RAWBODYMARKER"}}]}}]}]})
  end

  let!(:products) { create_menu }
  let!(:customer) { create_customer(number: phone, name: name) }
  let!(:username_customer) { Customer.resolve!(wa_user_id: user_id, display_name: "Sam Username") }
  let!(:order) { seed_order }
  let!(:deliveries) { seed_deliveries }

  def seed_order
    source = customer.conversation.messages.create!(direction: :inbound, message_type: "order", body: "order #{wamid}", wa_message_id: wamid,
                                                    raw_payload: { "id" => wamid, "from" => phone })
    open_window(customer.conversation, at: 2.hours.ago)
    order = create_order(customer: customer, source_message: source, total_cents: 2000, review_status: :needs_review,
                         wa_order_note: "note #{wamid}",
                         validation_issues: [ { "code" => "unknown_sku", "sku" => wamid, "expected" => wamid, "actual" => wamid } ])
    order.order_items.create!(product: products[0], product_retailer_id: "MAI-006", quantity: 1, item_price_cents: 1250, catalog_price_cents: 1550)
    create_outbound(customer: customer, order: order, status: :failed, purpose: "order_received", wa_message_id: "#{wamid}1", error_category: "auth_config",
                    error_title: "Token #{wamid}", error_details: "details #{wamid} for #{phone}", failed_at: Time.current, body: "Thanks #{wamid}")
    create_outbound(customer: customer, order: order, status: :blocked, purpose: "order_accepted", wa_message_id: "#{wamid}2", blocked_at: Time.current)
    create_outbound(customer: username_customer, status: :unknown, wa_message_id: "#{wamid}3")
    create_outbound(customer: username_customer, status: :accepted, wa_message_id: "#{wamid}4", accepted_at: 30.minutes.ago)
    create_outbound(customer: username_customer, status: :retry_scheduled, next_attempt_at: 1.minute.from_now, attempts: 1)
    order
  end

  def seed_deliveries
    items = [ { "kind" => "message", "ref" => wamid, "result" => "applied", "detail" => "message_id=1 #{wamid}" },
              { "kind" => "status", "ref" => wamid, "result" => "orphan", "detail" => "no outbound message matches" } ]
    outcome = { "summary" => { "applied" => 1, "orphan" => 1 }, "items" => items }
    %i[processed failed partially_failed unparseable ignored].map do |status|
      create_delivery(status: status, body: raw_body, signature_header: sign(raw_body), outcome: outcome,
                      last_error_class: "RuntimeError", last_error_message: "boom #{wamid} #{phone}", last_replayed_by: "amit")
    end
  end

  def admin_paths
    [
      "/admin", "/admin/health",
      "/admin/orders", *Admin::OrdersController::FILTERS.map { |f| "/admin/orders?filter=#{f}" }, "/admin/orders/#{order.id}",
      "/admin/conversations", *Conversation.pluck(:id).map { |id| "/admin/conversations/#{id}" },
      "/admin/deliveries", *WebhookDelivery.statuses.keys.map { |s| "/admin/deliveries?status=#{s}" }, *deliveries.map { |d| "/admin/deliveries/#{d.id}" },
      "/admin/products"
    ]
  end

  it "renders every admin page" do
    admin_paths.each do |path|
      get path
      expect(response).to have_http_status(:ok), "#{path} returned #{response.status}"
    end
  end

  it "never renders a Meta message id, wherever it is stored" do
    admin_paths.each do |path|
      get path
      expect(response.body).not_to include("wamid."), "#{path} rendered a wamid"
      expect(response.body).not_to include(wamid.last(20)), "#{path} rendered most of a Meta id"
    end
  end

  it "never renders a raw webhook body or anything from raw_payload" do
    admin_paths.each do |path|
      get path
      expect(response.body).not_to include("RAWBODYMARKER", "raw_body", "raw_payload", "entry"), path
    end
  end

  it "shows our own record ids instead of Meta's" do
    get "/admin/conversations/#{customer.conversation.id}"

    expect(response.body).to include("message ##{customer.conversation.messages.first.id}")
  end

  context "with DEMO_MASK_PII=1" do
    before { Rails.application.config.whatsapp.mask_pii = true }

    it "shows no name, phone number or user id on any page, and says so in the footer" do
      admin_paths.each do |path|
        get path
        body = response.body
        expect(body).not_to include("Jordan", "Rivera", "Sam Username", phone, "5550001", "1349120", "6302741"), path
        expect(body).to include("PII masked"), path
      end
    end

    it "shows the masked forms where customers appear" do
      get "/admin/conversations"

      expect(response.body).to include("Customer ##{customer.id}", "+•• ••••• •1234", "username user •••1918")
    end
  end

  context "without masking" do
    it "shows customers as they are and no PII footer" do
      get "/admin/conversations"

      expect(response.body).to include(name, "+#{phone}", "username user")
      expect(response.body).not_to include("PII masked")
    end
  end
end
