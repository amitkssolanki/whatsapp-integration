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
