require "rails_helper"

RSpec.describe "Admin conversations", type: :request do
  include_context "admin operator"

  let(:customer) { create_customer(number: "15550001234", name: "Jordan Rivera") }
  let(:conversation) { customer.conversation }

  def send_jobs = enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }

  def failed(category = "auth_config", **attrs)
    create_outbound(status: :failed, customer: customer, error_category: category, error_title: "Token expired", error_code: 190, failed_at: Time.current, **attrs)
  end

  describe "index" do
    it "lists conversations by latest activity with a window badge and message counts" do
      older = create_customer(number: "15550002222", name: "Older Olive")
      older.conversation.update!(last_message_at: 3.hours.ago, last_inbound_at: 30.hours.ago)
      open_window(conversation).update!(last_message_at: 1.minute.ago)
      create_outbound(customer: customer)
      Customer.resolve!(whatsapp_number: "15550003333", display_name: "Never Spoke")

      get "/admin/conversations"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("Jordan Rivera")).to be < body.index("Older Olive")
      expect(body.index("Older Olive")).to be < body.index("Never Spoke")
      expect(body).to include("window open", "window closed", "customer never wrote", "+15550001234")
      expect(body).to include('http-equiv="refresh"')
    end

    it "shows a username-only customer" do
      Customer.resolve!(wa_user_id: "US.13491208655302741918", display_name: "Sam")

      get "/admin/conversations"

      expect(response.body).to include("username user")
    end
  end

  describe "show" do
    it "renders the timeline oldest first with direction, purpose and each delivery state" do
      open_window(conversation, at: 1.hour.ago)
      conversation.messages.create!(direction: :inbound, message_type: "text", body: "first hello", created_at: 10.minutes.ago)
      states = {
        pending: {}, sending: {}, accepted: {}, sent: {}, delivered: {}, read: {},
        retry_scheduled: { next_attempt_at: 5.minutes.from_now, attempts: 2 },
        unknown: {}
      }
      states.each_with_index do |(status, attrs), index|
        create_outbound(status: status, customer: customer, body: "state #{status}", purpose: "reply", created_at: (9 - index).minutes.ago, **attrs)
      end
      failed("request_invalid", body: "state failed", created_at: 1.minute.ago)
      create_outbound(status: :blocked, customer: customer, body: "state blocked", error_category: "window_closed", blocked_at: Time.current, created_at: 30.seconds.ago)

      get "/admin/conversations/#{conversation.id}"

      expect(response).to have_http_status(:ok)
      body = response.body
      expect(body.index("first hello")).to be < body.index("state pending")
      expect(body.index("state pending")).to be < body.index("state blocked")
      expect(body).to include("← customer", "→ us", "reply")
      %w[pending sending accepted sent delivered read].each { |label| expect(body).to include("state-label\">#{label}") }
      expect(body).to include("✓✓", "retry scheduled", "next attempt", "outcome unknown", "blocked: 24h window", "request_invalid", "Token expired", "failed")
      expect(body).to include("Window open until")
    end

    it "does not auto-refresh while a blocked message shows its override checkbox" do
      create_outbound(status: :blocked, customer: customer, blocked_at: Time.current)

      get "/admin/conversations/#{conversation.id}"
      expect(response.body).not_to include('http-equiv="refresh"')

      get "/admin/conversations/#{create_customer(number: '15550009999').conversation.id}"
      expect(response.body).to include('http-equiv="refresh"')
    end

    it "shows 'Window closed at' when closed" do
      open_window(conversation, at: 2.days.ago)

      get "/admin/conversations/#{conversation.id}"

      expect(response.body).to include("Window closed at")
    end

    it "links the order a notification belongs to" do
      order = create_order(customer: customer)
      create_outbound(customer: customer, order: order, purpose: "order_received")

      get "/admin/conversations/#{conversation.id}"

      expect(response.body).to include("href=\"/admin/orders/#{order.id}\"")
    end

    it "offers Resend only for a failed message with a resendable category" do
      failed("auth_config")
      get "/admin/conversations/#{conversation.id}"
      expect(response.body).to include("Resend")

      Message.delete_all
      failed("request_invalid")
      get "/admin/conversations/#{conversation.id}"
      expect(response.body).not_to include(">Resend<")
    end

    it "offers Requeue only while the window is open, and the override experiment behind a checkbox" do
      create_outbound(status: :blocked, customer: customer, blocked_at: Time.current)

      get "/admin/conversations/#{conversation.id}"
      expect(response.body).not_to include(">Requeue<")
      expect(response.body).to include("Override window (experiment)", "I understand this sends outside the 24h window as a deliberate test")

      open_window(conversation)
      get "/admin/conversations/#{conversation.id}"
      expect(response.body).to include(">Requeue<")
    end

    it "offers no actions for a delivered message" do
      create_outbound(status: :delivered, customer: customer)

      get "/admin/conversations/#{conversation.id}"

      expect(response.body).not_to include(">Resend<", ">Requeue<", "Override window")
    end
  end

  describe "message actions" do
    it "resends a failed message as the operator and flashes success" do
      message = failed("account_config")

      post "/admin/messages/#{message.id}/resend"

      expect(response).to redirect_to("/admin/conversations/#{conversation.id}")
      expect(message.reload).to be_pending
      expect(send_jobs.size).to eq(1)
      follow_redirect!
      expect(response.body).to include("queued to send again")
    end

    it "flashes the refusal reason for a category that cannot be resent" do
      message = failed("request_invalid")

      post "/admin/messages/#{message.id}/resend"
      follow_redirect!

      expect(response.body).to include("Not done:", "request_invalid failure cannot be resent")
      expect(message.reload).to be_failed
    end

    it "returns to the page the action came from" do
      message = failed("account_config")

      post "/admin/messages/#{message.id}/resend", headers: { "HTTP_REFERER" => "http://www.example.com/admin/orders/1" }

      expect(response).to redirect_to("http://www.example.com/admin/orders/1")
    end

    it "requeues a blocked message when the window is open" do
      message = create_outbound(status: :blocked, customer: customer, blocked_at: Time.current, error_category: "window_closed")
      open_window(conversation)

      post "/admin/messages/#{message.id}/requeue"

      expect(message.reload).to be_pending
      expect(send_jobs.size).to eq(1)
    end

    it "refuses to requeue when the window is closed" do
      message = create_outbound(status: :blocked, customer: customer, blocked_at: Time.current)

      post "/admin/messages/#{message.id}/requeue"
      follow_redirect!

      expect(response.body).to include("the 24-hour window is closed")
      expect(message.reload).to be_blocked
    end

    it "records the operator on a window override, but only with the confirmation" do
      message = create_outbound(status: :blocked, customer: customer, blocked_at: Time.current)

      post "/admin/messages/#{message.id}/override_window"
      follow_redirect!
      expect(response.body).to include("tick the box to confirm")
      expect(message.reload).to be_blocked
      expect(send_jobs).to be_empty

      log = capture_log { post "/admin/messages/#{message.id}/override_window", params: { confirm: "1" } }

      expect(message.reload).to have_attributes(status: "pending", guard_override_by: AdminAuth::ADMIN_USER)
      expect(send_jobs.size).to eq(1)
      expect(log).to include("window.override_requested").and include("by=#{AdminAuth::ADMIN_USER}")
      follow_redirect!
      expect(response.body).to include("as an experiment")
    end

    it "refuses an override for a message that is not blocked" do
      message = create_outbound(status: :delivered, customer: customer)

      post "/admin/messages/#{message.id}/override_window", params: { confirm: "1" }
      follow_redirect!

      expect(response.body).to include("only a blocked message can be overridden")
    end

    it "404s for an inbound message" do
      inbound = conversation.messages.create!(direction: :inbound, message_type: "text", body: "hi")

      post "/admin/messages/#{inbound.id}/resend"

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PII masking" do
    before { Rails.application.config.whatsapp.mask_pii = true }

    it "hides the name and number on the list and the timeline" do
      create_outbound(customer: customer)
      conversation.messages.create!(direction: :inbound, message_type: "text", body: "hello")

      [ "/admin/conversations", "/admin/conversations/#{conversation.id}" ].each do |path|
        get path
        expect(response.body).not_to include("Jordan", "15550001234", "5550001"), path
        expect(response.body).to include("Customer ##{customer.id}", "+•• ••••• •1234", "PII masked"), path
      end
    end

    it "masks a username-only customer too" do
      sam = Customer.resolve!(wa_user_id: "US.13491208655302741918", display_name: "Sam")

      get "/admin/conversations/#{sam.conversation.id}"

      expect(response.body).not_to include("Sam<", "13491208655302741918", "6302741")
      expect(response.body).to include("username user")
    end
  end
end
