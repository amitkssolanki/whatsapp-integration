require "rails_helper"

RSpec.describe Ops::Purge do
  let(:before) { Time.utc(2026, 12, 1) }
  let(:old) { Time.utc(2026, 11, 1) }
  let(:recent) { Time.utc(2026, 12, 5) }
  let(:customer) { create_customer }
  let(:body) { meta_fixture("order") }

  before { travel_to(Time.utc(2027, 1, 15, 9)) } # after the purge date: BEFORE may not be in the future

  def delivery_at(time, **attrs)
    create_delivery(body: body, received_at: time, raw_body_base64: Base64.strict_encode64(body), signature_header: sign(body), **attrs)
  end

  def message_at(time, status: :delivered, customer: self.customer, **attrs)
    create_outbound(status: status, customer: customer, created_at: time, **attrs)
  end

  def inbound_at(time, customer: self.customer, **attrs)
    Message.create!({ conversation: customer.conversation, direction: :inbound, status: :received, message_type: "text", body: "my secret",
                      raw_payload: { "text" => { "body" => "my secret" } }, wa_message_id: "wamid.HBgMIN#{SecureRandom.hex(4)}", created_at: time }.merge(attrs))
  end

  def purge(**options) = described_class.new(before: before, **options).call

  describe "webhook deliveries" do
    it "blanks the body of settled deliveries received before the date and keeps everything aggregate" do
      old_delivery = delivery_at(old, status: :processed, outcome: { "summary" => { "applied" => 1 }, "items" => [] }, attempts: 2)
      new_delivery = delivery_at(recent)

      freeze_time do
        expect(purge).to include(deliveries: 1)
        expect(old_delivery.reload).to have_attributes(raw_body: "", raw_body_base64: nil, purged_at: Time.current, status: "processed",
                                                      attempts: 2, body_sha256: Digest::SHA256.hexdigest(body))
      end
      expect(old_delivery.outcome["summary"]).to eq("applied" => 1)
      expect(new_delivery.reload).to have_attributes(raw_body: body, purged_at: nil)
      expect(new_delivery.raw_body_base64).to be_present
    end

    it "replaces the Meta ids in the item outcomes by a fingerprint, keeping the results" do
      items = [ { "kind" => "message", "ref" => "wamid.HBgM15550100004", "result" => "applied", "detail" => nil },
                { "kind" => "status", "ref" => "wamid.HBgM15550100004", "result" => "orphan", "detail" => "no outbound message matches" } ]
      delivery = delivery_at(old, status: :processed, outcome: { "summary" => { "applied" => 1, "orphan" => 1 }, "items" => items })

      purge

      purged = delivery.reload.outcome["items"]
      expect(purged.map { |item| item["result"] }).to eq(%w[applied orphan])
      expect(purged.map { |item| item["ref"] }.uniq.sole).to match(/\Apurged:\h{12}\z/)
      expect(delivery.outcome.to_json).not_to include("15550100004")
    end

    it "treats the date as exclusive" do
      delivery_at(before, status: :processed)

      expect(purge).to include(deliveries: 0)
    end

    it "skips deliveries that are not settled, reports them by status, and purges them only with force" do
      held = %i[received processing failed partially_failed].map { |status| delivery_at(old, status: status) }
      settled = %i[processed ignored unparseable].map { |status| delivery_at(old, status: status) }

      result = purge
      expect(result).to include(deliveries: 3, skipped_deliveries: 4)
      expect(result[:held][:deliveries]).to eq("received" => 1, "processing" => 1, "failed" => 1, "partially_failed" => 1)
      expect(held.map { |d| d.reload.raw_body }).to all(eq(body))
      expect(settled.map { |d| d.reload.raw_body }).to all(eq(""))

      expect(purge(force: true)).to include(deliveries: 4, skipped_deliveries: 0)
      expect(held.map { |d| d.reload.raw_body }).to all(eq(""))
    end
  end

  describe "messages" do
    it "removes body, payload, Meta id and error details from settled messages, inbound and outbound" do
      old_out = message_at(old, status: :delivered, wa_message_id: "wamid.HBgMOUT1", error_details: "to 15550100004 failed")
      old_in = inbound_at(old)
      blocked = message_at(old, status: :blocked, error_details: "window")
      new_out = message_at(recent, wa_message_id: "wamid.HBgMNEW")

      freeze_time do
        expect(purge).to include(messages: 3)

        [ old_out, old_in, blocked ].each do |message|
          expect(message.reload).to have_attributes(body: nil, raw_payload: {}, wa_message_id: nil, error_details: nil, purged_at: Time.current)
        end
      end
      expect(new_out.reload).to have_attributes(body: "hello", wa_message_id: "wamid.HBgMNEW", purged_at: nil)
      expect(new_out.raw_payload).to eq("request" => { "type" => "text", "body" => "hello" })
    end

    it "skips outbound messages that are in flight, failed or unknown, reports them, and purges them only with force" do
      held = %i[pending sending retry_scheduled failed unknown].map { |status| message_at(old, status: status, wa_message_id: (status == :unknown ? "wamid.HBgMWAIT" : nil)) }
      done = message_at(old, status: :read)

      result = purge
      expect(result).to include(messages: 1, skipped_messages: 5)
      expect(result[:held][:messages]).to eq("pending" => 1, "sending" => 1, "retry_scheduled" => 1, "failed" => 1, "unknown" => 1)
      expect(held.map { |m| m.reload.raw_payload["request"] }).to all(be_present)
      expect(held.last.reload.wa_message_id).to eq("wamid.HBgMWAIT")
      expect(done.reload).to have_attributes(body: nil, raw_payload: {})

      expect(purge(force: true)).to include(messages: 5, skipped_messages: 0)
      expect(held.map { |m| m.reload.body }).to all(be_nil)
    end

    it "does not change statuses or timestamps, or touch updated_at" do
      message = message_at(old, status: :read, read_at: old, body: "hello")
      stamp = message.reload.updated_at

      purge

      expect(message.reload).to have_attributes(status: "read", read_at: old, updated_at: stamp)
    end
  end

  describe "orders" do
    it "clears the order note of orders placed before the date" do
      old_order = create_order(customer: customer, wa_order_note: "no onions, call 15550100004", created_at: old)
      new_order = create_order(customer: customer, wa_order_note: "extra napkins", created_at: recent)

      expect(purge).to include(orders: 1)

      expect(old_order.reload.wa_order_note).to be_nil
      expect(new_order.reload.wa_order_note).to eq("extra napkins")
    end
  end

  describe "customers" do
    let(:quiet) { create_customer(number: "15550100010", name: "Quiet Quentin") }

    before do
      inbound_at(old, customer: quiet)
      quiet.conversation.update_columns(last_inbound_at: old, last_message_at: old)
      quiet.update_columns(created_at: old)
    end

    it "anonymises a customer whose last activity is before the date, keeping the identity constraint satisfied" do
      freeze_time do
        expect(purge).to include(customers: 1)

        expect(quiet.reload).to have_attributes(display_name: nil, whatsapp_number: nil, wa_user_id: "purged:#{quiet.id}", purged_at: Time.current, purged_had_phone: true)
        expect(quiet).to be_purged
      end
    end

    it "keeps a customer who was active after the date, in any way" do
      chatty = create_customer(number: "15550100011", name: "Chatty Chloe")
      chatty.update_columns(created_at: old)
      inbound_at(old, customer: chatty)
      inbound_at(recent, customer: chatty)

      ordering = create_customer(number: "15550100012", name: "Ordering Olive")
      ordering.update_columns(created_at: old)
      create_order(customer: ordering, created_at: recent)

      expect(purge).to include(customers: 1)

      expect([ chatty, ordering ].map { |c| c.reload.whatsapp_number }).to eq(%w[15550100011 15550100012])
      expect(chatty.display_name).to eq("Chatty Chloe")
      expect(quiet.reload.whatsapp_number).to be_nil
    end

    it "handles a customer known only by user id and keeps unique user ids unique" do
      username = Customer.resolve!(wa_user_id: "US.77", display_name: "Handle")
      username.update_columns(created_at: old)

      expect(purge).to include(customers: 2)

      expect(username.reload).to have_attributes(wa_user_id: "purged:#{username.id}", whatsapp_number: nil, purged_had_phone: false)
      expect(Customer.pluck(:wa_user_id).uniq.size).to eq(Customer.count)
    end

    it "skips a customer who still has an outbound message to send, reports it, and anonymises it with force" do
      message_at(old, status: :pending, customer: quiet)

      result = purge
      expect(result).to include(customers: 0, skipped_customers: 1)
      expect(quiet.reload).to have_attributes(whatsapp_number: "15550100010", display_name: "Quiet Quentin", purged_at: nil)

      expect(purge(force: true)).to include(customers: 1, skipped_customers: 0)
      expect(quiet.reload.whatsapp_number).to be_nil
    end

    it "lets a returning person start a fresh customer record, because the old number is gone" do
      purge

      returning = Customer.resolve!(whatsapp_number: "15550100010", display_name: "Quentin")

      expect(returning.id).not_to eq(quiet.id)
      expect(returning).not_to be_purged
    end
  end

  describe "operator actions on purged data" do
    it "refuses to resend, requeue or override a purged message with the reason 'purged'" do
      failed = message_at(old, status: :failed, error_category: "unclassified")
      blocked = message_at(old, status: :blocked)
      purge(force: true)

      expect(failed.reload.resend!(by: "amit")).to have_attributes(refused?: true, reason: "purged")
      expect(blocked.reload.requeue!(by: "amit")).to have_attributes(refused?: true, reason: "purged")
      expect(blocked.override_window_send!(by: "amit")).to have_attributes(refused?: true, reason: "purged")
      expect(failed.reload).to be_failed
    end

    it "refuses to decide an order whose customer was purged" do
      menu = create_menu
      order = create_order(customer: customer, created_at: old, source_message: nil)
      customer.update_columns(created_at: old)
      purge

      expect(order.reload.accept!(by: "amit")).to have_attributes(refused?: true, reason: /purged/)
      expect(order.reload).to be_received
      expect(menu).to be_present
    end
  end

  describe "the report" do
    def report(from: Time.utc(2026, 10, 1), to: Time.utc(2026, 12, 31))
      Ops::Report.new(from: from, to: to).call.deep_dup.tap { |data| data[:period].delete(:generated_at) }
    end

    it "gives the same counts and statuses after a purge as before" do
      with_phone = create_customer(number: "15550100020", name: "Phoned")
      username = Customer.resolve!(wa_user_id: "US.88")
      [ with_phone, username ].each do |c|
        c.update_columns(created_at: old)
        inbound_at(old, customer: c)
      end
      delivery_at(old, status: :processed, outcome: { "summary" => { "applied" => 2 }, "items" => [ { "kind" => "message", "ref" => "wamid.X", "result" => "applied", "detail" => nil } ] })
      delivery_at(old.advance(hours: 1), status: :processed)
      delivery_at(old.advance(hours: 2), status: :processed) # an exact duplicate body of the first
      create_order(customer: with_phone, created_at: old, wa_order_note: "note")
      %i[delivered read blocked accepted].each { |status| message_at(old, status: status, customer: with_phone, accepted_at: old, delivered_at: old + 5.seconds) }
      message_at(old, status: :failed, customer: with_phone, error_category: "unclassified", failed_at: old)

      before_purge = report
      expect(purge(force: true)).to include(customers: 2, messages: 7)
      after_purge = report

      expect(before_purge[:inbound]).to include(distinct_customers: 2, customers_without_phone: 1)
      expect(after_purge).to eq(before_purge)
    end
  end

  it "refuses a date in the future" do
    expect { described_class.new(before: 1.day.from_now) }.to raise_error(Ops::Purge::FutureDate, /future/)
  end

  it "is idempotent: a second run counts nothing" do
    delivery_at(old, status: :processed)
    message_at(old)
    quiet = create_customer(number: "15550100010")
    quiet.update_columns(created_at: old)
    create_order(customer: quiet, created_at: old, wa_order_note: "x")

    expect(purge).to include(deliveries: 1, messages: 1, customers: 2, orders: 1)
    expect(purge).to include(deliveries: 0, messages: 0, customers: 0, orders: 0)
  end

  it "previews the same counts without changing anything" do
    old_delivery = delivery_at(old, status: :processed)
    message_at(old)
    delivery_at(old, status: :failed)

    preview = described_class.new(before: before).preview
    expect(preview).to include(deliveries: 1, messages: 1, skipped_deliveries: 1, skipped_messages: 0)
    expect(old_delivery.reload).to have_attributes(raw_body: body, purged_at: nil)
    expect(Message.where.not(purged_at: nil)).to be_empty
  end

  it "logs a warning with the counts" do
    delivery_at(old, status: :processed)

    log = capture_log { purge }

    expect(log).to include("event=ops.purge", "deliveries=1", "before=2026-12-01T00:00:00Z")
  end
end
