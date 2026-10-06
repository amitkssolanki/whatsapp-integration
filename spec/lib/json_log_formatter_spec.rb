require "rails_helper"
require Rails.root.join("lib/json_log_formatter")

RSpec.describe JsonLogFormatter do
  let(:io) { StringIO.new }
  let(:logger) { ActiveSupport::TaggedLogging.new(Logger.new(io)).tap { |l| l.formatter = described_class.new } }
  let(:uuid) { "6f1d1d9a-3a77-4c0e-9b36-0c6f3a1d2e55" }

  def lines = io.string.lines.map { |line| JSON.parse(line) }

  it "writes one JSON object per line with time, level and message" do
    logger.info("event=webhook.stored delivery_id=1")

    expect(lines.sole).to include("level" => "INFO", "message" => "event=webhook.stored delivery_id=1")
    expect(lines.sole["time"]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/)
    expect(lines.sole).not_to include("tags", "request_id", "job_id")
  end

  it "labels a web request line with its request id and the tags array" do
    logger.tagged("req-abc-123") { logger.info("hello") }

    expect(lines.sole).to include("request_id" => "req-abc-123", "tags" => [ "req-abc-123" ])
  end

  it "does not call a job's tag a request id: ActiveJob lines get tags and the real job_id" do
    logger.tagged("ActiveJob", "SendMessageJob", uuid) { logger.info("Performing") }

    line = lines.sole
    expect(line).to include("tags" => [ "ActiveJob", "SendMessageJob", uuid ], "job_id" => uuid)
    expect(line).not_to have_key("request_id")
  end

  it "labels the enqueue-time ActiveJob tag (no job id yet) without a request id or job id" do
    logger.tagged("ActiveJob") { logger.info("Enqueued") }

    expect(lines.sole).to include("tags" => [ "ActiveJob" ])
    expect(lines.sole).not_to include("request_id", "job_id")
  end

  it "keeps both ids when a job runs inline inside a request" do
    logger.tagged("req-1") { logger.tagged("ActiveJob", "ProcessWebhookDeliveryJob", uuid) { logger.info("inline") } }

    expect(lines.sole).to include("request_id" => "req-1", "job_id" => uuid, "tags" => [ "req-1", "ActiveJob", "ProcessWebhookDeliveryJob", uuid ])
  end

  it "does not invent a job_id from a tag that is not a uuid" do
    logger.tagged("ActiveJob", "SomeJob", "not-a-uuid") { logger.info("x") }

    expect(lines.sole).not_to have_key("job_id")
  end

  it "strips and stringifies the message, including exceptions, and never raises on odd input" do
    logger.info("  padded \n")
    logger.error(RuntimeError.new("boom"))
    logger.info(nil)

    expect(lines.map { |line| line["message"] }).to eq([ "padded", "boom (RuntimeError)", "nil" ])
  end

  it "is what production uses, and it labels a real ActiveJob run correctly" do
    expect(Rails.root.join("config/environments/production.rb").read).to include("JsonLogFormatter.new")

    job_class = Class.new(ApplicationJob) do
      def self.name = "FormatterProbeJob"

      def perform = logger.info("inside the job")
    end
    job_class.logger = logger
    job_class.new.tap { |job| job.logger = logger }.perform_now

    line = lines.find { |entry| entry["message"] == "inside the job" }
    expect(line["tags"]).to start_with("ActiveJob", "FormatterProbeJob")
    expect(line["job_id"]).to match(JsonLogFormatter::UUID)
    expect(line).not_to have_key("request_id")
  end
end
