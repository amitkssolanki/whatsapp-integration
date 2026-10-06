require "rails_helper"

# A smoke test of the whole scenario script against the test database, with the
# development-only guard bypassed explicitly. Nothing here may touch the network.
RSpec.describe Demo::Simulator do
  before { create_menu }

  def simulate(**options) = described_class.new(enforce_guard: false, **options).call

  def scenario(result, key) = result.scenarios.find { |s| s.key == key }

  describe ".refusal" do
    let(:development) { ActiveSupport::EnvironmentInquirer.new("development") }
    let(:demo_url) { "postgres:///whatsapp_integration_demo" }

    it "never runs in production" do
      production = ActiveSupport::EnvironmentInquirer.new("production")

      expect(described_class.refusal(rails_env: production, env: { "DATABASE_URL" => demo_url }, database: "x_demo")).to match(/never runs in production/)
    end

    it "runs only in development" do
      expect(described_class.refusal(rails_env: ActiveSupport::EnvironmentInquirer.new("test"), env: { "DATABASE_URL" => demo_url }, database: "x_demo"))
        .to match(/only in development/)
    end

    it "requires DATABASE_URL to name a _demo database, and says how to run it" do
      [ {}, { "DATABASE_URL" => "postgres:///whatsapp_integration_development" } ].each do |env|
        reason = described_class.refusal(rails_env: development, env: env, database: "whatsapp_integration_development")

        expect(reason).to include("_demo", "DATABASE_URL=postgres:///whatsapp_integration_demo bin/rails db:prepare db:seed demo:simulate")
      end
    end

    it "also requires the connected database itself to be a demo one" do
      reason = described_class.refusal(rails_env: development, env: { "DATABASE_URL" => demo_url }, database: "whatsapp_integration_development")

      expect(reason).to include("connected to \"whatsapp_integration_development\"")
    end

    it "allows development against a demo database" do
      expect(described_class.refusal(rails_env: development, env: { "DATABASE_URL" => demo_url }, database: "whatsapp_integration_demo")).to be_nil
    end
  end

  it "refuses to run when the guard is enforced (the test environment is not development)" do
    expect { described_class.new.call }.to raise_error(Demo::Refused, /only in development/)
    expect(Customer.count).to eq(0)
  end

  it "refuses without seeded products" do
    Product.destroy_all

    expect { simulate }.to raise_error(Demo::Refused, /at least 2 in-stock products/)
  end

  context "after a full run" do
    let(:log) { capture_log { @result = simulate } }
    let(:result) { log && @result }

    before { expect(Net::HTTP).not_to receive(:start) }

    it "behaves as designed in every scenario, with zero real HTTP" do
      expect(result.scenarios.map(&:key)).to eq(%i[greeting clean_order price_drift unknown_sku duplicate_status replay retry ambiguous blocked])
      failures = result.scenarios.flat_map { |s| s.checks.reject(&:last).map { |description, _| "#{s.key}: #{description}" } }
      expect(failures).to be_empty
      expect(result).to be_passed

      expect(graph.calls).to eq(0) # the spec's strict graph was never reached
      expect(result.fake_requests).to eq(9) # greeting, 2 receipts + notice, drift receipt, unknown-SKU receipt, replayed receipt, 503 + retry, timed-out reply
    end

    it "creates three simulated customers and nothing that identifies as real" do
      result

      expect(Customer.order(:id).map(&:display_name)).to eq([ "Demo Customer 1", "Demo Customer 2", "Demo Customer 3" ])
      expect(Customer.pluck(:whatsapp_number)).to all(match(/\A1555010\d{4}\z/))
      expect(Message.where.not(wa_message_id: nil).pluck(:wa_message_id)).to all(start_with("wamid.DEMO."))
      expect(WebhookDelivery.pluck(:raw_body)).to all(include('"simulated":true'))
    end

    it "leaves the expected records for each scenario" do
      result

      # greeting: a catalog card to customer 1, read
      card = Message.outbound.find_by!(purpose: "greeting", message_type: "interactive", status: "read")
      expect(card.conversation.customer.display_name).to eq("Demo Customer 1")

      # orders: clean accepted, price drift (accepted at the end), unknown SKU, and the replayed one
      expect(Order.count).to eq(4)
      expect(Order.accepted.clear.count).to eq(1)
      expect(Order.needs_review.pluck(:validation_issues).flatten.map { |issue| issue["code"] }).to match_array(%w[price_mismatch unknown_sku])
      expect(Order.received.clear.count).to eq(1)
      expect(Order.accepted.needs_review.count).to eq(1)

      # duplicate status: two stored deliveries with one body, one applied and one duplicate
      duplicates = WebhookDelivery.where("outcome->'summary' ? 'duplicate'")
      expect(duplicates.count).to eq(1)
      expect(WebhookDelivery.where(body_sha256: duplicates.first.body_sha256).count).to eq(2)

      # replay: the injected failure replayed once, one order from it
      replayed = WebhookDelivery.where(replay_count: 1).sole
      expect(replayed).to be_processed
      expect(replayed.outcome["items"].sole["result"]).to eq("applied")
      expect(Order.where(source_message_id: Message.inbound.where(webhook_delivery_id: replayed.id).select(:id)).count).to eq(1)

      # retry: attempted twice, the second succeeded
      expect(Message.outbound.where(attempts: 2).sole).to have_attributes(status: "delivered", error_category: nil, purpose: "greeting")

      # ambiguous: sent once, never retried
      unknown = Message.outbound.unknown.sole
      expect(unknown).to have_attributes(attempts: 1, wa_message_id: nil, error_category: "ambiguous")
      expect(unknown.unknown_at).to be_present

      # blocked: by the window, Meta not called
      blocked = Message.outbound.blocked.sole
      expect(blocked).to have_attributes(purpose: "order_accepted", error_category: "window_closed", attempts: 1)
      expect(blocked.conversation.last_inbound_at).to be < 1.day.ago

      expect(Message.outbound.group(:status).count).to eq("read" => 3, "delivered" => 4, "unknown" => 1, "blocked" => 1)
      expect(Message.inbound.count).to eq(7)
    end

    it "tags every application log event of the run as simulated, including the injected fault" do
      events = log.lines.select { |line| line.include?("event=") }

      expect(events).not_to be_empty
      expect(events).to all(include("simulated=true"))
      expect(events.join).to include("event=fault.injected", "event=demo.simulation_started", "event=demo.simulation_finished")
    end

    it "leaves the process as it found it, and summarises the run as simulated" do
      result
      config = Rails.application.config.whatsapp

      expect(config.token).to be_nil
      expect(config.phone_number_id).to be_nil
      expect(config.app_secret).to eq(TEST_APP_SECRET)
      expect(ENV["FAULT_INJECT"]).to be_nil
      expect(WhatsappClient.adapter).to eq(graph.adapter)
      expect(ActiveJob::Base.queue_adapter).to be_a(ActiveJob::QueueAdapters::TestAdapter)
      expect(SolidQueue::Job.count).to eq(0)

      summary = described_class.summary(result)
      expect(summary).to include("SIMULATED DATA", "PASS  Hi -> catalog card -> read", "demo customers: 3", "Find simulated records")
      expect(summary).not_to include("FAIL")
    end
  end

  it "can run again on the same database: unique ids, same behaviour" do
    simulate
    second = simulate

    expect(second).to be_passed
    expect(Customer.count).to eq(3)
    expect(Order.count).to eq(8)
    expect(Message.where.not(wa_message_id: nil).count).to eq(Message.where.not(wa_message_id: nil).distinct.count(:wa_message_id))
  end

  it "is deterministic for a seed: the same quantities in the same order, whatever is already in the database" do
    simulate(seed: 7)
    first = OrderItem.order(:id).pluck(:quantity)
    simulate(seed: 7)

    expect(OrderItem.order(:id).pluck(:quantity).drop(first.size)).to eq(first)
  end

  it "leaves the process untouched even when a scenario blows up" do
    allow(Order).to receive(:find_by!).and_raise("boom")

    result = simulate

    expect(result).not_to be_passed
    expect(result.scenarios.flat_map(&:checks).map(&:first)).to include(a_string_matching(/ran without raising \(RuntimeError: boom\)/))
    expect(WhatsappClient.adapter).to eq(graph.adapter)
    expect(ENV["FAULT_INJECT"]).to be_nil
  end
end
