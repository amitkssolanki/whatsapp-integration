require "rails_helper"

# The three operating-period toggles (docs/operating/PROTOCOL.md 4, 6, 7), end to
# end through the real code paths, and the guarantee that nothing fires unset.
RSpec.describe "Fault injection", type: :request do
  include_context "admin operator"

  let!(:menu) { create_menu }
  let(:order_body) { meta_fixture("order") }
  let(:customer) { create_customer }

  # The order fixture was sent to this business number; other numbers are ignored.
  before do
    configure_whatsapp
    Rails.application.config.whatsapp.phone_number_id = "100000000000005"
  end

  def send_job(message) = SendMessageJob.perform_now(message.id)

  def outbound_ready
    open_window(customer.conversation)
    create_outbound(customer: customer)
  end

  describe "processing:order" do
    before { inject_faults("processing:order") }

    it "fails the order item, labels it, and leaves nothing behind" do
      log = capture_log { @delivery = deliver_and_process(order_body) }
      delivery = @delivery

      expect(delivery).to be_failed
      expect(delivery.outcome["items"].sole).to include("result" => "error")
      expect(delivery.outcome["items"].sole["detail"]).to include("injected:processing:order")
      expect(delivery.last_error_class).to eq("FaultInjection::Injected")
      expect([ Order.count, Message.count, Customer.count ]).to eq([ 0, 0, 0 ])
      expect(log).to include("event=fault.injected", "kind=processing:order", "delivery_id=#{delivery.id}")
    end

    it "can be replayed once the toggle is removed: exactly one order" do
      delivery = deliver_and_process(order_body)
      expect(delivery).to be_failed

      ENV.delete("FAULT_INJECT")
      delivery.replay!(by: "operator")
      process_deliveries

      expect(delivery.reload).to be_processed
      expect(Order.count).to eq(1)
      expect(Message.inbound.count).to eq(1)
    end

    it "does not touch other message types" do
      Rails.application.config.whatsapp.phone_number_id = "100000000000003"
      delivery = deliver_and_process(meta_fixture("text_greeting"))

      expect(delivery).to be_processed
    end

    it "keeps the label on the delivery page" do
      delivery = deliver_and_process(order_body)

      get "/admin/deliveries/#{delivery.id}"
      expect(response.body).to include("injected:processing:order")
    end
  end

  describe "send:5xx" do
    before { inject_faults("send:5xx") }

    it "returns a synthetic transient 503 without calling Meta, schedules a retry and labels the row" do
      message = outbound_ready
      log = capture_log { send_job(message) }

      expect(graph.calls).to eq(0)
      expect(message.reload).to have_attributes(status: "retry_scheduled", error_category: "transient_platform", attempts: 1)
      expect(message.error_details).to start_with("[injected]")
      expect(log).to include("event=fault.injected", "kind=send:5xx", "message_id=#{message.id}")
    end

    it "succeeds on the retry once the toggle is removed" do
      message = outbound_ready
      send_job(message)
      ENV.delete("FAULT_INJECT")
      graph.reply(200, ok_send("wamid.AFTER"))

      send_job(message)

      expect(message.reload).to have_attributes(status: "accepted", attempts: 2, wa_message_id: "wamid.AFTER")
      expect(graph.calls).to eq(1)
    end

    it "returns the injected result from the client directly" do
      result = WhatsappClient.new.send_message(recipient: customer, request: { "type" => "text", "body" => "hi" }, callback_id: 1)

      expect(result).to have_attributes(http_status: 503, category: "transient_platform", retryable: true, ambiguous: false)
      expect(result.details).to start_with("[injected]")
    end
  end

  describe "send:read_timeout_after_send" do
    before { inject_faults("send:read_timeout_after_send") }

    it "performs the real request, discards the response and leaves the message unknown" do
      message = outbound_ready
      graph.reply(200, ok_send("wamid.DISCARDED"))
      log = capture_log { send_job(message) }

      expect(graph.calls).to eq(1)
      expect(message.reload).to have_attributes(status: "unknown", error_category: "ambiguous", wa_message_id: nil)
      expect(message.error_details).to start_with("[injected]")
      expect(log).to include("event=fault.injected", "kind=send:read_timeout_after_send")
      expect(log).not_to include("wamid.DISCARDED")
    end

    it "never retries it" do
      message = outbound_ready
      graph.reply(200, ok_send)
      send_job(message)
      send_job(message)

      expect(graph.calls).to eq(1)
      expect(enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }).to be_empty
    end
  end

  describe "with nothing set" do
    it "fires nothing: the order is processed, the send reaches Meta and is accepted, no fault event is logged" do
      message = outbound_ready
      graph.reply(200, ok_send("wamid.REAL"))

      log = capture_log do
        expect(deliver_and_process(order_body)).to be_processed
        send_job(message)
      end

      expect(message.reload).to be_accepted
      expect(message.error_details).to be_nil
      expect(Order.count).to eq(1)
      expect(log).not_to include("fault.injected")
    end

    it "ignores toggles outside development and test unless explicitly allowed" do
      inject_faults("send:5xx")
      allow(Rails.env).to receive(:local?).and_return(false)
      message = outbound_ready
      graph.reply(200, ok_send)

      send_job(message)

      expect(message.reload).to be_accepted
    end
  end

  describe "the Health banner" do
    it "is absent when nothing is injected" do
      get "/admin/health"

      expect(response.body).not_to include("Fault injection is ACTIVE")
    end

    it "is a red alert listing every active toggle" do
      inject_faults("processing:order", "send:5xx")

      get "/admin/health"

      expect(response.body).to include("banner-bad", "Fault injection is ACTIVE", "<code>processing:order</code>", "<code>send:5xx</code>")
    end

    it "mentions toggles that are set but ignored" do
      inject_faults("send:nonsense")

      get "/admin/health"

      expect(response.body).not_to include("Fault injection is ACTIVE")
      expect(response.body).to include("send:nonsense")
    end
  end

  describe "the Health switch" do
    include_context "admin operator"

    def switch(kinds, confirm: "1") = post("/admin/fault_injection", params: { kinds: kinds, confirm: confirm }.compact)

    it "shows the panel where injection is allowed, with a checkbox per kind and a confirm box" do
      get "/admin/health"

      expect(response.body).to include("fault-injection-panel", "Fault injection")
      FaultInjection::KINDS.each { |kind| expect(response.body).to include(%(value="#{kind}")) }
      expect(response.body).to include('name="confirm"')
    end

    it "does not show the panel, and refuses the switch, where injection is not allowed" do
      allow(Rails.env).to receive(:local?).and_return(false)
      allow(Rails.env).to receive(:production?).and_return(true)

      get "/admin/health"
      expect(response.body).not_to include("fault-injection-panel")

      switch(%w[send:5xx])
      expect(OpsSetting.current.fault_inject).to eq([])
      expect(flash[:alert]).to match(/not allowed/)
    end

    it "switches toggles on as the operator, shows the red banner, and switches them off again without a confirm" do
      switch(%w[send:5xx processing:order])

      expect(OpsSetting.current).to have_attributes(fault_inject: %w[send:5xx processing:order], updated_by: "operator")
      get "/admin/health"
      expect(response.body).to include("Fault injection is ACTIVE", "<code>send:5xx</code>", "<code>processing:order</code>")

      switch([], confirm: nil)

      expect(OpsSetting.current.fault_inject).to eq([])
      get "/admin/health"
      expect(response.body).not_to include("Fault injection is ACTIVE")
    end

    it "needs the confirm box to switch something on, and ignores unknown kinds" do
      switch(%w[send:5xx], confirm: nil)
      expect(OpsSetting.current.fault_inject).to eq([])

      switch(%w[send:5xx send:explode])
      expect(OpsSetting.current.fault_inject).to eq(%w[send:5xx])
    end

    it "makes a toggle fire on the next send and stop on the next, with no restart" do
      switch(%w[send:5xx])
      first = outbound_ready
      graph.reply(200, ok_send)
      send_job(first)
      expect(first.reload).to be_retry_scheduled
      expect(graph.calls).to eq(0)

      switch([], confirm: nil)
      second = outbound_ready
      send_job(second)
      expect(second.reload).to be_accepted
    end
  end
end
