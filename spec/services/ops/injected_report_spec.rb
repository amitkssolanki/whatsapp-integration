require "rails_helper"
require "rake"

# Review 2 #6: injected and simulated evidence must never be mixed into the
# numbers that describe real platform behaviour.
RSpec.describe Ops::Report, "real versus injected" do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:t) { Time.utc(2026, 10, 20, 10) }
  let(:report) { described_class.new(from: from, to: to).call }
  let(:real_customer) { create_customer(number: "15550100001", name: "Real Person") }
  let(:demo_customer) { create_customer(number: "15550100002", name: "Demo Customer 3") }

  def delivery(**attrs) = create_delivery(received_at: t, status: :processed, **attrs)

  def message(customer, **attrs) = create_outbound(customer: customer, created_at: t, **attrs)

  it "keeps injected deliveries out of every real delivery metric and counts them in all" do
    body = '{"object":"whatsapp_business_account","entry":[{"id":"1"}]}'
    delivery(body: body, outcome: { "summary" => { "applied" => 1 }, "items" => [] })
    delivery(body: body, received_at: t + 1.minute, injected_faults: [ "injected:repost" ], outcome: { "summary" => { "duplicate" => 1 }, "items" => [] })
    delivery(body: '{"object":"x"}', received_at: t + 2.minutes, status: :failed, replay_count: 1, injected_faults: [ "injected:processing:order" ],
             outcome: { "summary" => { "error" => 1 }, "items" => [ { "kind" => "message", "ref" => "r", "result" => "error", "detail" => "x" } ] })

    real = report[:real][:deliveries]
    all = report[:all][:deliveries]

    expect(real).to include(total: 1, exact_duplicate_bodies: 0, replays: { total: 0, deliveries_replayed: 0 })
    expect(real[:by_status]).to include("processed" => 1, "failed" => 0)
    expect(real[:item_outcomes]).to include("applied" => 1, "duplicate" => 0, "error" => 0)
    expect(all).to include(total: 3, exact_duplicate_bodies: 1, replays: { total: 1, deliveries_replayed: 1 })
    expect(all[:by_status]).to include("processed" => 2, "failed" => 1)
    expect(all[:item_outcomes]).to include("applied" => 1, "duplicate" => 1, "error" => 1)
  end

  it "keeps injected and simulated outbound messages out of the real metrics" do
    message(real_customer, status: :delivered, purpose: "order_received", accepted_at: t, sent_at: t + 1, delivered_at: t + 3)
    message(real_customer, status: :failed, error_category: "transient_exhausted", error_code: 131_000, attempts: 3, injected_faults: [ "injected:send:5xx" ])
    message(real_customer, status: :unknown, unknown_at: t, injected_faults: [ "injected:send:read_timeout_after_send" ])
    message(demo_customer, status: :delivered, purpose: "greeting", accepted_at: t, sent_at: t + 10, delivered_at: t + 60)
    message(demo_customer, status: :failed, error_category: "unclassified", error_code: 131_047)

    real = report[:real][:outbound]
    all = report[:all][:outbound]

    expect(real).to include(total: 1, injected_faults: 0, unknown_unresolved: 0)
    expect(real[:by_status]).to include("delivered" => 1, "failed" => 0, "unknown" => 0)
    expect(real[:failed_by_error_category]).to eq({})
    expect(real[:attempts]).to eq(total: 0, messages_retried: 0)
    expect(real[:unknown]).to include(count: 0)

    expect(all).to include(total: 5, injected_faults: 2, unknown_unresolved: 1)
    expect(all[:by_status]).to include("delivered" => 2, "failed" => 2, "unknown" => 1)
    expect(all[:failed_by_error_category]).to eq("transient_exhausted" => 1, "unclassified" => 1)
    expect(all[:attempts][:messages_retried]).to eq(1)

    expect(report[:real][:window]).to eq(blocked_window_closed: 0, failures_131047: 0, disagreements: 0)
    expect(report[:all][:window]).to include(failures_131047: 1)
  end

  it "takes latency from real rows only, in both groups" do
    message(real_customer, status: :delivered, accepted_at: t, sent_at: t + 2, delivered_at: t + 4)
    message(demo_customer, status: :delivered, accepted_at: t, sent_at: t + 100, delivered_at: t + 1000)
    message(real_customer, status: :delivered, accepted_at: t, sent_at: t + 500, delivered_at: t + 900, injected_faults: [ "injected:send:5xx" ])

    expect(report[:real][:latency][:accepted_to_delivered]).to eq(n: 1, median: 4.0, min: 4.0, max: 4.0)
    expect(report[:all][:latency]).to eq(report[:real][:latency])
  end

  it "summarises what was injected, by label" do
    delivery(body: "{}", injected_faults: [ "injected:repost" ])
    delivery(body: '{"a":1}', injected_faults: [ "injected:repost", "injected:processing:order" ])
    delivery(body: '{"b":1}')
    message(real_customer, status: :failed, injected_faults: [ "injected:send:5xx" ])
    message(real_customer, status: :delivered)

    expect(report[:injected]).to eq(
      deliveries: { total: 2, by_label: { "injected:processing:order" => 1, "injected:repost" => 2 } },
      messages: { total: 1, by_label: { "injected:send:5xx" => 1 } }
    )
  end

  it "renders real first, all second, then the injected summary" do
    delivery(body: "{}", injected_faults: [ "injected:repost" ])

    markdown = described_class.new(from: from, to: to).to_markdown

    expect(markdown.index("## Real: Webhook deliveries")).to be < markdown.index("## All (injected and simulated rows included): Webhook deliveries")
    expect(markdown.index("## All (injected")).to be < markdown.index("## Injected and re-posted rows")
    expect(markdown).to include("| deliveries.by_label.injected:repost | 1 |")
  end

  describe "ops:repost_delivery" do
    include ActiveJob::TestHelper

    before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("ops:repost_delivery") }

    let(:task) { Rake::Task["ops:repost_delivery"] }
    let!(:menu) { create_menu }

    def run_task(**env)
      task.reenable
      saved = ENV.to_h.slice("ID", "CONFIRM")
      %w[ID CONFIRM].each { |key| ENV.delete(key) }
      env.each { |key, value| ENV[key.to_s] = value }
      yield
    ensure
      %w[ID CONFIRM].each { |key| ENV.delete(key) }
      saved.each { |key, value| ENV[key] = value }
    end

    it "re-ingests the stored bytes and signature as a new delivery labeled injected:repost, never counted as a real duplicate" do
      original = deliver_and_process(meta_fixture("order"))

      copy = nil
      run_task(ID: original.id.to_s, CONFIRM: "yes") { expect { task.invoke }.to output(/delivery ##{original.id} as delivery #\d+.*injected:repost/).to_stdout }
      copy = WebhookDelivery.where.not(id: original.id).sole
      expect(copy).to have_attributes(injected_faults: [ "injected:repost" ], body_sha256: original.body_sha256, signature_header: original.signature_header,
                                      raw_body: original.raw_body, status: "received")
      expect(enqueued_jobs.count { |job| job["job_class"] == "ProcessWebhookDeliveryJob" && job["arguments"].first == copy.id }).to eq(1)

      process_deliveries
      expect(copy.reload).to be_processed
      expect(copy.outcome["summary"]).to eq("duplicate" => 1)
      expect([ Order.count, Message.inbound.count ]).to eq([ 1, 1 ])

      window = described_class.new(from: copy.received_at - 1.hour, to: copy.received_at + 1.hour).call
      expect(window[:real][:deliveries]).to include(total: 1, exact_duplicate_bodies: 0)
      expect(window[:all][:deliveries]).to include(total: 2, exact_duplicate_bodies: 1)
      expect(window[:injected][:deliveries]).to eq(total: 1, by_label: { "injected:repost" => 1 })
    end

    it "keeps non-UTF-8 bodies byte exact" do
      body = %({"object":"whatsapp_business_account","entry":[],"x":"\xFF"}).b
      original = Webhooks::Ingest.new(raw_body: body, signature_header: sign(body), request_id: "t").call
      expect(original.raw_body_base64).to be_present

      copy = Ops::Repost.new(original.id).call

      expect(copy.raw_bytes).to eq(body)
      expect(copy.injected_faults).to eq([ "injected:repost" ])
    end

    it "refuses without CONFIRM=yes, without an id, for an unknown, purged or badly signed delivery" do
      original = deliver_and_process(meta_fixture("order"))

      run_task(ID: original.id.to_s) { expect { task.invoke }.to raise_error(SystemExit).and output(/CONFIRM=yes/).to_stderr }
      run_task(CONFIRM: "yes") { expect { task.invoke }.to raise_error(SystemExit).and output(/ID=/).to_stderr }
      run_task(ID: "0", CONFIRM: "yes") { expect { task.invoke }.to raise_error(SystemExit).and output(/no webhook delivery/).to_stderr }
      original.update_columns(signature_header: "sha256=#{'0' * 64}")
      run_task(ID: original.id.to_s, CONFIRM: "yes") { expect { task.invoke }.to raise_error(SystemExit).and output(/signature/).to_stderr }
      original.update_columns(purged_at: Time.current, raw_body: "", raw_body_base64: nil)
      run_task(ID: original.id.to_s, CONFIRM: "yes") { expect { task.invoke }.to raise_error(SystemExit).and output(/purged/).to_stderr }

      expect(WebhookDelivery.count).to eq(1)
    end

    it "labels the copy in the same transaction: a failing enqueue leaves no unlabeled copy behind" do
      original = deliver_and_process(meta_fixture("order"))
      allow(ProcessWebhookDeliveryJob).to receive(:perform_later).and_return(false)

      expect { Ops::Repost.new(original.id).call }.to raise_error(ApplicationJob::EnqueueFailed)

      expect(WebhookDelivery.count).to eq(1)
    end
  end
end
