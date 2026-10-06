require "rails_helper"

RSpec.describe Health::Snapshot do
  let(:now) { Time.utc(2026, 10, 6, 12, 0, 0) }
  let(:customer) { create_customer }
  let(:snapshot) { described_class.new(now: now).call }

  before { travel_to(now) }

  def outbound(status, **attrs) = create_outbound(status: status, customer: customer, **attrs)

  def delivery(status, summary: nil, received_at: now - 1.hour, **attrs)
    create_delivery(status: status, received_at: received_at, outcome: summary ? { "items" => [], "summary" => summary } : {}, **attrs)
  end

  it "is all zeros and empty lists on an empty database, with no active banner" do
    expect(snapshot[:deliveries].values.map { |l| l[:count] }).to eq([ 0, 0, 0, 0 ])
    expect(snapshot[:outbound][:by_status].values).to all(eq(0))
    expect(snapshot[:outbound][:failed_by_category]).to eq({})
    expect(snapshot[:orders][:needs_review]).to eq(count: 0, recent: [])
    expect(snapshot[:anomalies]).to include(orphan_items: 0, anomaly_items: 0)
    expect(snapshot[:queue][:failed_executions]).to eq(0)
    expect(snapshot[:config_banner][:active]).to be(false)
  end

  describe "deliveries" do
    it "counts failed and partially failed regardless of age, and unparseable and ignored only inside the window" do
      delivery(:failed, received_at: now - 30.days)
      delivery(:partially_failed, received_at: now - 30.days)
      delivery(:unparseable)
      delivery(:unparseable, received_at: now - 30.days)
      delivery(:ignored)
      delivery(:ignored)
      delivery(:processed)
      delivery(:received)

      counts = snapshot[:deliveries].transform_values { |list| list[:count] }

      expect(counts).to eq(failed: 1, partially_failed: 1, unparseable: 1, ignored: 2)
    end

    it "lists the newest first and caps the list" do
      12.times { |i| delivery(:failed, received_at: now - i.hours) }

      list = snapshot[:deliveries][:failed]

      expect(list[:count]).to eq(12)
      expect(list[:recent].size).to eq(10)
      expect(list[:recent].map(&:received_at)).to eq(list[:recent].map(&:received_at).sort.reverse)
    end
  end

  describe "outbound" do
    it "counts every outbound status, ignoring inbound rows" do
      Message.create!(conversation: customer.conversation, direction: :inbound, status: :received, message_type: "text")
      outbound(:pending)
      outbound(:pending)
      outbound(:sending)
      outbound(:accepted, accepted_at: now)
      outbound(:read)

      by_status = snapshot[:outbound][:by_status]

      expect(by_status).to include("pending" => 2, "sending" => 1, "accepted" => 1, "read" => 1, "failed" => 0, "unknown" => 0)
      expect(by_status).not_to have_key("received")
    end

    it "groups failures by category, with a bucket for uncategorised ones" do
      outbound(:failed, error_category: "auth_config", failed_at: now)
      outbound(:failed, error_category: "auth_config", failed_at: now)
      outbound(:failed, error_category: "request_invalid", failed_at: now)
      outbound(:failed, failed_at: now)

      expect(snapshot[:outbound][:failed_by_category]).to eq("auth_config" => 2, "request_invalid" => 1, "uncategorised" => 1)
    end

    it "lists unknown, blocked and retry_scheduled messages" do
      unknown = outbound(:unknown)
      blocked = outbound(:blocked, blocked_at: now)
      retrying = outbound(:retry_scheduled, next_attempt_at: now + 1.minute)

      expect(snapshot[:outbound][:unknown][:recent]).to eq([ unknown ])
      expect(snapshot[:outbound][:blocked]).to eq(count: 1, recent: [ blocked ])
      expect(snapshot[:outbound][:retry_scheduled]).to eq(count: 1, recent: [ retrying ])
    end

    it "reports undelivered with the same rule as Message.undelivered (accepted or sent for 10+ minutes, no delivered_at)" do
      stuck = outbound(:accepted, accepted_at: now - 11.minutes)
      outbound(:sent, accepted_at: now - 11.minutes, delivered_at: now)
      outbound(:accepted, accepted_at: now - 2.minutes)
      outbound(:delivered, accepted_at: now - 11.minutes, delivered_at: now)

      expect(snapshot[:outbound][:undelivered]).to eq(count: 1, recent: [ stuck ])
      expect(Message.undelivered.to_a).to eq([ stuck ])
    end
  end

  it "lists undecided orders that need review, and not decided or clear ones" do
    flagged = create_order(customer: customer, review_status: :needs_review)
    create_order(customer: customer, review_status: :needs_review, status: :accepted)
    create_order(customer: customer)

    expect(snapshot[:orders][:needs_review]).to eq(count: 1, recent: [ flagged ])
  end

  describe "anomalies" do
    it "sums orphan and anomaly items from recent delivery outcomes" do
      with_orphans = delivery(:processed, summary: { "applied" => 1, "orphan" => 2 })
      with_anomaly = delivery(:processed, summary: { "anomaly" => 1, "duplicate" => 3 })
      delivery(:processed, summary: { "applied" => 4 })
      delivery(:processed, summary: { "orphan" => 5 }, received_at: now - 30.days)
      delivery(:received)

      anomalies = snapshot[:anomalies]

      expect(anomalies).to include(orphan_items: 2, anomaly_items: 1)
      expect(anomalies[:deliveries][:recent]).to contain_exactly(with_orphans, with_anomaly)
      expect(anomalies[:deliveries][:count]).to eq(2)
    end
  end

  describe "the queue" do
    it "counts Solid Queue failed executions" do
      job = SolidQueue::Job.create!(queue_name: "default", class_name: "SendMessageJob", arguments: "{}")
      SolidQueue::FailedExecution.create!(job: job, error: "boom")

      expect(snapshot[:queue][:failed_executions]).to eq(1)
    end
  end

  describe "the config banner" do
    it "is active when every failure in the last hour is an auth_config or account_config one" do
      outbound(:failed, error_category: "auth_config", error_code: 190, error_title: "Token expired", failed_at: now - 10.minutes)
      outbound(:failed, error_category: "account_config", error_code: 133010, failed_at: now - 20.minutes)

      expect(snapshot[:config_banner]).to include(
        active: true, categories: %w[account_config auth_config], failures: 2, latest_error_code: 190, latest_error_title: "Token expired", latest_failed_at: now - 10.minutes
      )
    end

    it "is inactive when any recent failure has another category" do
      outbound(:failed, error_category: "auth_config", failed_at: now - 10.minutes)
      outbound(:failed, error_category: "recipient_not_allowed", failed_at: now - 5.minutes)

      expect(snapshot[:config_banner][:active]).to be(false)
    end

    it "ignores failures older than an hour" do
      outbound(:failed, error_category: "auth_config", failed_at: now - 2.hours)

      expect(snapshot[:config_banner][:active]).to be(false)
    end

    it "clears itself once a message has been accepted after the latest failure" do
      outbound(:failed, error_category: "auth_config", failed_at: now - 10.minutes)
      outbound(:accepted, accepted_at: now - 5.minutes)

      expect(snapshot[:config_banner][:active]).to be(false)
    end

    it "stays active when the only accepted message predates the failure" do
      outbound(:accepted, accepted_at: now - 30.minutes)
      outbound(:failed, error_category: "auth_config", failed_at: now - 10.minutes)

      expect(snapshot[:config_banner][:active]).to be(true)
    end
  end

  it "is read-only: it writes nothing" do
    outbound(:failed, error_category: "auth_config", failed_at: now)
    delivery(:failed)

    expect { described_class.new.call }.not_to(change { [ Message.maximum(:updated_at), WebhookDelivery.maximum(:updated_at) ] })
  end
end
