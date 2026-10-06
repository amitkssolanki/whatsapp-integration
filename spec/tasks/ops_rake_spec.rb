require "rails_helper"
require "rake"

RSpec.describe "ops:report" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("ops:report") }

  let(:task) { Rake::Task["ops:report"] }

  def run_task(**env)
    task.reenable
    saved = ENV.to_h.slice("FROM", "TO", "FORMAT")
    %w[FROM TO FORMAT].each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key.to_s] = value }
    yield
  ensure
    %w[FROM TO FORMAT].each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
  end

  it "prints JSON for the given dates" do
    create_delivery(received_at: Time.utc(2026, 10, 25, 12))
    output = nil
    run_task(FROM: "2026-10-20", TO: "2026-11-10") { output = capture_stdout { task.invoke } }

    data = JSON.parse(output)
    expect(data["period"]).to include("from" => "2026-10-20T00:00:00Z", "to" => "2026-11-10T00:00:00Z")
    expect(data["real"]["deliveries"]["total"]).to eq(1)
  end

  it "defaults to the last 24 hours as JSON" do
    output = nil
    run_task { output = capture_stdout { task.invoke } }

    period = JSON.parse(output)["period"]
    expect(Time.zone.parse(period["to"]) - Time.zone.parse(period["from"])).to eq(24.hours)
  end

  it "prints Markdown with FORMAT=md" do
    output = nil
    run_task(FORMAT: "md", FROM: "2026-10-20", TO: "2026-10-21") { output = capture_stdout { task.invoke } }

    expect(output).to start_with("# Operations report")
  end

  it "refuses an unknown format or a reversed period" do
    run_task(FORMAT: "xml") { expect { task.invoke }.to raise_error(SystemExit).and output(/FORMAT must be/).to_stderr }
    run_task(FROM: "2026-11-10", TO: "2026-10-20") { expect { task.invoke }.to raise_error(SystemExit).and output(/before to/).to_stderr }
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end
end

RSpec.describe "ops:purge" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("ops:purge") }

  let(:task) { Rake::Task["ops:purge"] }
  let(:body) { '{"object":"whatsapp_business_account","entry":[]}' }
  let(:cutoff) { Date.current.iso8601 }
  let!(:old_delivery) { create_delivery(body: body, received_at: 40.days.ago, status: :processed) }
  let!(:old_message) { create_outbound(created_at: 40.days.ago, status: :delivered, wa_message_id: "wamid.HBgMX") }
  let!(:held_message) { create_outbound(created_at: 40.days.ago, status: :failed, customer: create_customer(number: "15550100077")) }

  before do
    Customer.update_all(created_at: 40.days.ago)
    Conversation.update_all(created_at: 40.days.ago, updated_at: 40.days.ago)
  end

  def run_task(name: "ops:purge", **env)
    task = Rake::Task[name]
    task.reenable
    Rake::Task["ops:purge"].reenable
    saved = ENV.to_h.slice("BEFORE", "CONFIRM", "FORCE")
    %w[BEFORE CONFIRM FORCE].each { |key| ENV.delete(key) }
    env.each { |key, value| ENV[key.to_s] = value }
    yield task
  ensure
    %w[BEFORE CONFIRM FORCE].each { |key| ENV.delete(key) }
    saved.each { |key, value| ENV[key] = value }
  end

  it "purges and prints the counts per table, including what it skipped, with BEFORE and CONFIRM=yes" do
    run_task(BEFORE: cutoff, CONFIRM: "yes") do |task|
      expect { task.invoke }.to output(/webhook_deliveries.*purged: 1.*messages.*purged: 1.*customers.*anonymised: 1.*orders.*cleared: 0.*SKIPPED.*outbound messages:\s+1 \{"failed" => 1\}.*customers with such a message: 1/m).to_stdout
    end

    expect(old_delivery.reload).to have_attributes(raw_body: "", purged_at: be_present)
    expect(old_message.reload).to have_attributes(raw_payload: {}, body: nil, wa_message_id: nil)
    expect(held_message.reload.body).to eq("hello")
  end

  it "purges what it skipped only with FORCE=yes" do
    run_task(BEFORE: cutoff, CONFIRM: "yes", FORCE: "yes") do |task|
      expect { task.invoke }.to output(/\(FORCE\)/).to_stdout
    end

    expect(held_message.reload.body).to be_nil
  end

  it "is also available under its old name, ops:purge_payloads" do
    before_all = Rake::Task["ops:purge_payloads"]
    expect(before_all.prerequisites).to eq([ "purge" ])

    run_task(name: "ops:purge_payloads", BEFORE: cutoff, CONFIRM: "yes") do |task|
      expect { task.invoke }.to output(/Purged before/).to_stdout
    end
    expect(old_delivery.reload.purged_at).to be_present
  end

  it "refuses without CONFIRM=yes, says what it would do and changes nothing" do
    [ {}, { CONFIRM: "y" }, { CONFIRM: "true" } ].each do |extra|
      run_task(BEFORE: cutoff, **extra) do |task|
        expect { task.invoke }.to raise_error(SystemExit).and output(/without CONFIRM=yes.*webhook_deliveries.*to purge: 1.*messages.*to purge: 1.*SKIPPED/m).to_stderr
      end
    end

    expect(old_delivery.reload).to have_attributes(raw_body: body, purged_at: nil)
    expect(old_message.reload.raw_payload).not_to eq({})
  end

  it "refuses a missing, malformed, impossible or future BEFORE" do
    [ nil, "12/01/2026", "2026-13-45", "2999-01-01" ].each do |value|
      run_task(**{ BEFORE: value, CONFIRM: "yes" }.compact) do |task|
        expect { task.invoke }.to raise_error(SystemExit).and output(/BEFORE/).to_stderr
      end
    end

    expect(old_delivery.reload.purged_at).to be_nil
  end
end
