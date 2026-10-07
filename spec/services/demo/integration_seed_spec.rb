require "rails_helper"

# demo:seed_integration is meant to be run INSIDE production, next to the real
# token. These specs run it with FakeGraph strict (any real HTTP call raises) and
# check what it guarantees: zero HTTP, only synthetic rows, deterministic counts,
# a clean end state, and no effect on anything that is not synthetic.
RSpec.describe Demo::IntegrationSeed do
  def seed = described_class.new.call

  def synthetic_messages = Message.where(conversation_id: Conversation.where(customer_id: Customer.synthetic.select(:id)).select(:id))

  def table_counts
    [ Customer, Conversation, Message, Order, OrderItem, WebhookDelivery, Product, Category ].to_h { |model| [ model.name, model.unscoped.count ] }
  end

  describe "a full run" do
    let!(:result) do
      configure_whatsapp # a "real" token and phone number id are in force before the run
      Rails.application.config.whatsapp.token = "the-real-production-token"
      seed
    end

    it "passes every scenario, with zero real HTTP (FakeGraph strict, the tripwire and Net::HTTP never touched)" do
      failures = result.scenarios.flat_map { |s| s.checks.reject(&:last).map { |description, _| "#{s.key}: #{description}" } }

      expect(failures).to be_empty
      expect(result).to be_passed
      expect(result.scenarios.map(&:key)).to eq(%i[greeting clean_order price_mismatch unknown_sku unavailable invalid_quantity permanent_failure
                                                  ambiguous duplicate_status replay rejected blocked])
      expect(graph.calls).to eq(0)
      expect(Demo::Sandbox.blocked_connections).to eq(0)
      expect(result.fake_requests).to eq(14)
      expect(Demo::Sandbox).not_to be_entered
    end

    it "never put the real token anywhere: no stored row mentions it, and the config is restored" do
      expect(Rails.application.config.whatsapp.token).to eq("the-real-production-token")
      expect(Rails.application.config.whatsapp.phone_number_id).to eq("100000000000003")
      expect(Rails.application.config.whatsapp.app_secret).to eq(TEST_APP_SECRET)
      dump = [ Message, WebhookDelivery, Order ].flat_map { |model| model.all.map { |row| row.attributes.to_s } }.join
      expect(dump).not_to include("the-real-production-token")
    end

    it "creates only synthetic customers, deliveries and products, with unmistakably fake identifiers" do
      expect(Customer.pluck(:synthetic)).to all(be(true))
      expect(Customer.order(:id).map(&:display_name)).to eq(described_class::CUSTOMER_NAMES)
      expect(Customer.order(:id).map(&:display_name)).to eq(
        [ "Maya Fernandes", "Daniel Okafor", "Sofia Marino", "Tom Becker", "Aisha Khan", "Lucas Moreau",
          "Hannah Lee", "Ravi Shah", "Elena Petrova", "Ben Carter", "Nora Lindqvist" ]
      )
      expect(Customer.order(:id).pluck(:whatsapp_number)).to eq((2001..2011).map { |n| "1555010#{n}" })
      expect(Customer.pluck(:whatsapp_number)).to all(match(/\A1555010\d{4}\z/))
      # Never a real number: in particular never an Indian (+91) number such as the
      # project's real business number, which stays out of tracked files.
      expect(Customer.pluck(:whatsapp_number).grep(/\A91/)).to be_empty
      expect(WebhookDelivery.pluck(:synthetic)).to all(be(true))
      expect(WebhookDelivery.pluck(:raw_body)).to all(include('"simulated":true'))
      expect(Product.pluck(:synthetic)).to all(be(true))
      expect(Product.order(:sku).pluck(:sku)).to eq(%w[DEMO-AVAIL-1 DEMO-AVAIL-2 DEMO-OOS-1 DEMO-PRICE-1])
      expect(Product.find_by!(sku: "DEMO-OOS-1")).to be_out_of_stock
      expect(Product.pluck(:currency).uniq).to eq([ "USD" ])
      expect(Category.sole.name).to eq("Demo items (synthetic)")
      expect(Product.pluck(:category_id).uniq).to eq([ Category.sole.id ])

      ids = Message.where.not(wa_message_id: nil).pluck(:wa_message_id)
      expect(ids).to all(start_with("sim."))
      expect(Message.inbound.pluck(:wa_message_id)).to all(match(/\Asim\.in\.\d+\z/))
      expect(Message.outbound.where.not(wa_message_id: nil).pluck(:wa_message_id)).to all(match(/\Asim\.out\.\d+\z/))
      expect(WebhookDelivery.pluck(:raw_body).join).not_to include("wamid.")
    end

    it "leaves exactly the designed states, scenario by scenario" do
      expect(result.counts).to eq(
        "products" => 4, "customers" => 11, "conversations" => 11, "inbound messages" => 12, "outbound messages" => 15,
        "orders" => 8, "order items" => 10, "webhook deliveries" => 41
      )
      expect(result.states["outbound messages"]).to eq("blocked" => 1, "delivered" => 6, "failed" => 1, "read" => 5, "sent" => 1, "unknown" => 1)
      expect(result.states["orders (status/review)"]).to eq("accepted/clear" => 2, "received/clear" => 1, "received/needs_review" => 4, "rejected/clear" => 1)
      expect(result.states["webhook deliveries"]).to eq("processed" => 41)

      expect(Order.needs_review.flat_map { |o| o.validation_issues.map { |i| i["code"] } }).to match_array(%w[price_mismatch unknown_sku unavailable invalid_quantity])
      failed = Message.outbound.failed.sole
      expect(failed).to have_attributes(error_code: 131026, error_category: "recipient_undeliverable", attempts: 1)
      expect(Message.outbound.unknown.sole).to have_attributes(error_category: "ambiguous", attempts: 1, wa_message_id: nil)
      expect(Message.outbound.blocked.sole).to have_attributes(error_category: "window_closed", purpose: "order_accepted")
      expect(Order.rejected.sole.rejection_reason).to start_with("kitchen_closed")
      expect(WebhookDelivery.where("outcome->'summary' ? 'duplicate'").count).to eq(1) # the status that was delivered twice
      replayed = WebhookDelivery.where(replay_count: 1).sole
      expect(replayed.outcome["summary"]).to eq("applied" => 1)
      expect(replayed.injected_faults).to eq([ "injected:processing:order" ])
    end

    it "ends clean: nothing in flight, no Solid Queue job, nothing left in the in-process queue" do
      expect(Message.outbound.where(status: %w[pending sending retry_scheduled])).to be_empty
      expect(SolidQueue::Job.count).to eq(0)
      expect(ActiveJob::Base.queue_adapter).not_to be_a(Demo::InlineQueue)
      expect(SendMessageJob._queue_adapter).not_to be_a(Demo::InlineQueue)
      expect(WhatsappClient.adapter).to eq(graph.adapter)
      expect(Catalog::Client.adapter).not_to eq([ :test ]) # restored to whatever it was
    end

    it "spreads timestamps over the last few days, all in the past, in order within a conversation" do
      times = Message.pluck(:created_at) + WebhookDelivery.pluck(:received_at) + Order.pluck(:created_at) + Customer.pluck(:created_at)

      expect(times.max).to be < result.anchor
      expect(result.anchor).to be <= Time.current
      expect(times.min).to be > result.anchor - 5.days
      expect(times.min).to be < result.anchor - 4.days
      expect(times.map { |t| t.to_date }.uniq.size).to be >= 5
      Conversation.find_each do |conversation|
        created = conversation.messages.chronological.pluck(:created_at)
        expect(created).to eq(created.sort)
      end
      expect(Message.pluck(:created_at, :updated_at).all? { |created, updated| updated >= created }).to be(true)
      expect(Order.where.not(decided_at: nil).all? { |o| o.decided_at > o.created_at }).to be(true)
    end

    it "makes the 24-hour window real: the late acceptance was blocked by the guard, not faked" do
      blocked = Message.outbound.blocked.sole

      expect(blocked.conversation.last_inbound_at).to be < blocked.created_at - 24.hours
      expect(blocked.conversation).not_to be_window_open(at: blocked.created_at)
    end

    it "makes everything it created unsendable and unreplayable afterwards (the production guards)" do
      delivery = WebhookDelivery.where(replay_count: 1).sole
      expect(delivery).not_to be_replayable
      expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::NotReplayable, /synthetic/)

      customer = Customer.synthetic.first
      open_window(customer.conversation)
      message = create_outbound(customer: customer)
      SendMessageJob.perform_now(message.id)

      expect(graph.calls).to eq(0)
      expect(message.reload).to have_attributes(status: "failed", error_category: "synthetic_recipient")
    end

    it "keeps the synthetic products out of the public menu and the feed" do
      expect(Product.synthetic.count).to eq(4)
      expect(Category.on_menu).to be_empty
      expect(Catalog::FeedGenerator.new(base_url: "https://example.test").to_csv).not_to include("DEMO-")
    end
  end

  describe "the hero scenario (customer 1, Maya Fernandes)" do
    it "reads like a real interaction on the real menu: greeting, a three-line order with a note, receipt and notice delivered and read" do
      create_menu({ "MAI-006" => 1550, "MAI-004" => 1950, "BEV-002" => 500 })
      result = seed

      expect(result).to be_passed
      maya = Customer.synthetic.find_by!(display_name: "Maya Fernandes")
      messages = maya.conversation.messages.chronological
      expect(messages.map { |m| [ m.direction, m.purpose, m.status ] }).to eq(
        [ [ "inbound", nil, "received" ], %w[outbound greeting read], [ "inbound", nil, "received" ],
          %w[outbound order_received read], %w[outbound order_accepted read] ]
      )
      expect(messages.first.body).to eq("Hi! What's on the menu today?")
      expect(messages.second.message_type).to eq("interactive")

      order = maya.orders.sole
      expect(order.order_items.order(:id).pluck(:product_retailer_id, :quantity, :item_price_cents)).to eq(
        [ [ "MAI-006", 2, 1550 ], [ "MAI-004", 1, 1950 ], [ "BEV-002", 2, 500 ] ]
      )
      expect(order.total_cents).to eq(6050)
      expect(order.formatted_total).to eq("$60.50")
      expect(order).to be_accepted
      expect(order).to be_clear
      expect(order.wa_order_note).to eq("Delivery around 7:30 please")
      expect(order.decided_by).to eq("demo-operator")

      %w[order_received order_accepted].each do |purpose|
        expect(messages.find { |m| m.purpose == purpose }).to have_attributes(sent_at: be_present, delivered_at: be_present, read_at: be_present)
      end
      expect(result.counts["order items"]).to eq(11)
      expect(Customer.synthetic.pluck(:whatsapp_number).grep(/\A91/)).to be_empty
    end
  end

  describe "determinism" do
    it "gives identical counts and states every run, replacing (not adding to) the previous synthetic data" do
      first = seed
      first_ids = Customer.pluck(:id)
      second = seed
      third = seed

      expect(second.counts).to eq(first.counts)
      expect(second.states).to eq(first.states)
      expect(third.counts).to eq(first.counts)
      expect(second.deleted).to include(customers: 11, messages: 27, orders: 8, webhook_deliveries: 41, products: 4, categories: 1)
      expect(Customer.count).to eq(11)
      expect(Customer.pluck(:id) & first_ids).to be_empty
      expect(Message.where.not(wa_message_id: nil).count).to eq(Message.where.not(wa_message_id: nil).distinct.count(:wa_message_id))
      expect(Product.count).to eq(4)
      expect(Category.count).to eq(1)
    end
  end

  describe "isolation from real data and production state" do
    let!(:menu) { create_menu }
    let(:real_customer) { create_customer(number: "15550100077", name: "Real Customer") }

    def real_snapshot
      [ real_customer, real_customer.conversation, @real_message, @real_order, @real_delivery, *menu ].map { |record| record.reload.attributes }
    end

    before do
      open_window(real_customer.conversation)
      @real_message = create_outbound(customer: real_customer, status: :pending)
      @real_order = create_order(customer: real_customer)
      @real_delivery = create_delivery(status: :failed)
      @before = real_snapshot
      @counts_before = table_counts
    end

    it "never touches a non-synthetic row, and never sends anything pending for a real customer" do
      seed

      expect(real_snapshot).to eq(@before)
      expect(Customer.non_synthetic.count).to eq(1)
      expect(Product.non_synthetic.count).to eq(menu.size)
      expect(@real_message.reload).to be_pending
      expect(graph.calls).to eq(0)
    end

    it "features a REAL product on the catalog card when the real menu exists" do
      seed

      card = Message.outbound.find_by!(purpose: "greeting", message_type: "interactive")
      expect(card.raw_payload.dig("request", "thumbnail_product_retailer_id")).to eq("MAI-006")
    end

    it "ignores the operator's stored fault toggles and never writes them, and works as if in production without FAULT_INJECTION_ALLOWED" do
      OpsSetting.current.update!(fault_inject: %w[processing:order send:5xx send:read_timeout_after_send], updated_by: "amit", updated_at: Time.utc(2026, 10, 1))
      stored = OpsSetting.current.attributes
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

      result = seed

      expect(result).to be_passed
      expect(OpsSetting.current.attributes).to eq(stored)
      expect(Message.outbound.where.not(injected_faults: []).count).to eq(0) # no stored toggle fired
      expect(WebhookDelivery.where.not(injected_faults: []).count).to eq(1)  # only the script's own injected failure
    end

    it "ignores a FAULT_INJECT environment variable and leaves it as it was" do
      ENV["FAULT_INJECT"] = "send:5xx"

      expect(seed).to be_passed
      expect(ENV["FAULT_INJECT"]).to eq("send:5xx")
    end

    it "rolls EVERYTHING back, the reset included, and restores the process, when an end-state guarantee is violated" do
      seeded = seed
      expect(seeded).to be_passed
      state = table_counts
      synthetic_ids = Customer.synthetic.order(:id).pluck(:id)
      allow_any_instance_of(Demo::FakeMeta).to receive(:catalog_requests).and_return([ { path: "/x" } ])

      expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /rolled everything back.*Catalog::Client was called/m)

      expect(table_counts).to eq(state) # the previous synthetic data is still there, nothing half-created
      # The same rows, not deleted and re-created. (This line used to compare an
      # unordered query with an ordered one, which tested nothing and failed
      # intermittently on Postgres row order.)
      expect(Customer.synthetic.order(:id).pluck(:id)).to eq(synthetic_ids)
      expect(Demo::Sandbox).not_to be_entered
      expect(WhatsappClient.adapter).to eq(graph.adapter)
      expect(@real_message.reload).to be_pending
    end

    it "rolls back and says why when a scenario does not behave as designed" do
      allow(Order).to receive(:find_by!).and_raise("boom")

      expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /scenario clean_order failed.*boom/m)

      expect(table_counts).to eq(@counts_before)
    end

    it "rolls back when a synthetic message is left in flight" do
      allow_any_instance_of(Demo::InlineQueue).to receive(:performed).and_return(0)

      expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /no job ran/)
      expect(table_counts).to eq(@counts_before)
    end

    it "refuses (and rolls back) if a real HTTP connection is attempted during the run" do
      allow(Demo::Sandbox).to receive(:blocked_connections).and_return(1)

      expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /a network connection was attempted/)
      expect(table_counts).to eq(@counts_before)
    end

    it "refuses (and rolls back) if a synthetic delivery of the run is not synthetic" do
      allow_any_instance_of(Webhooks::Ingest).to receive(:call).and_wrap_original do |original|
        original.call.tap { |delivery| WebhookDelivery.where(id: delivery.id).update_all(synthetic: false) }
      end

      expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /deliveries of this run are not synthetic/)
      expect(table_counts).to eq(@counts_before)
    end
  end

  it "never so much as creates the OpsSetting row (fault injection is a process-local override)" do
    OpsSetting.delete_all

    expect(seed).to be_passed
    expect(OpsSetting.count).to eq(0)
  end

  it "surfaces a stuck Solid Queue job for the run as a violation" do
    allow_any_instance_of(described_class).to receive(:solid_queue_jobs?).and_return(true)

    expect { seed }.to raise_error(Demo::IntegrationSeed::Violation, /Solid Queue holds jobs/)
    expect(Customer.count).to eq(0)
  end

  describe ".summary" do
    it "counts per table and per state, and says it is synthetic" do
      summary = described_class.summary(seed)

      expect(summary).to include("SYNTHETIC DATA", "14 calls answered by the in-process fake", "PASS  Hi -> catalog card -> read",
                                 "customers: 11", "outbound messages: blocked 1, delivered 6, failed 1, read 5, sent 1, unknown 1", "demo:purge_synthetic")
      expect(summary).not_to include("FAIL")
    end
  end
end
