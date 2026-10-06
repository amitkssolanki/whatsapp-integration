module WebhookHelpers
  META_FIXTURES = Rails.root.join("spec/fixtures/meta/v1")

  # Raw bytes of a sanitized real V1 payload (see spec/fixtures/meta/v1/README.md).
  def meta_fixture(name)
    META_FIXTURES.join("#{name}.json").read
  end

  def sign(body, secret = TEST_APP_SECRET)
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
  end

  # POST a body to the webhook, signed with the test app secret unless told otherwise.
  def post_webhook(body, signature: sign(body), headers: {})
    request_headers = { "Content-Type" => "application/json" }.merge(headers)
    request_headers["X-Hub-Signature-256"] = signature if signature
    post "/webhooks/whatsapp", params: body, headers: request_headers
  end

  # Runs a block with an extra logger attached to Rails.logger and returns
  # everything written during it (including SQL and request log lines).
  def capture_log
    io = StringIO.new
    logger = ActiveSupport::Logger.new(io)
    Rails.logger.broadcast_to(logger)
    yield
    io.string
  ensure
    Rails.logger.stop_broadcasting_to(logger)
  end
end

RSpec.configure do |config|
  config.include WebhookHelpers
  config.include ActiveJob::TestHelper, type: :request
  config.include ActiveJob::TestHelper, type: :job
  config.include ActiveJob::TestHelper, type: :integration
end

# Helpers for specs that push real payloads through ingestion and processing
# without the HTTP layer.
module PipelineHelpers
  # Stores a body exactly as the controller would (signed, one transaction with
  # its job) and returns the delivery. Processing happens in `process_deliveries`.
  def deliver(body)
    Webhooks::Ingest.new(raw_body: body, signature_header: sign(body), request_id: "spec").call
  end

  # Runs only the webhook jobs that are queued; SendMessageJob stays queued so
  # specs can assert it was enqueued.
  def process_deliveries
    perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
  end

  def deliver_and_process(body)
    delivery = deliver(body)
    process_deliveries
    delivery.reload
  end

  def fixture_json(name) = JSON.parse(meta_fixture(name))

  # The wa id of the first message/status in a fixture.
  def fixture_wa_id(name)
    value = fixture_json(name).dig("entry", 0, "changes", 0, "value")
    (value["messages"] || value["statuses"]).first["id"]
  end

  def enqueued_send_ids
    enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }.map { |job| job["arguments"].first }
  end
end

RSpec.configure { |config| config.include PipelineHelpers }
