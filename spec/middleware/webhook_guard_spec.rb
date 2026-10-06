require "rails_helper"

RSpec.describe WebhookGuard do
  let(:inner) { ->(env) { [ 200, { "content-type" => "text/plain" }, [ env["rack.input"].read ] ] } }
  let(:guard) { described_class.new(inner, max_body_bytes: 100) }

  def env_for(path: "/webhooks/whatsapp", method: "POST", body: "{}", length: :auto, signature: "sha256=abc", input: nil)
    env = Rack::MockRequest.env_for(path, method: method, input: input || StringIO.new(body))
    env.delete("CONTENT_LENGTH")
    env["CONTENT_LENGTH"] = (length == :auto ? body.bytesize : length).to_s unless length.nil?
    env["HTTP_X_HUB_SIGNATURE_256"] = signature if signature
    env
  end

  it "passes a signed, small POST through untouched" do
    status, _headers, body = guard.call(env_for(body: '{"a":1}'))

    expect([ status, body.first ]).to eq([ 200, '{"a":1}' ])
  end

  it "answers 413 for a declared length over the limit without reading the body" do
    input = instance_double(StringIO)
    expect(input).not_to receive(:read)

    status, = guard.call(env_for(length: 101, input: input))

    expect(status).to eq(413)
  end

  it "accepts a body of exactly the limit" do
    status, = guard.call(env_for(body: "x" * 100))

    expect(status).to eq(200)
  end

  it "answers 413 for a chunked body (no Content-Length) that outgrows the limit while being read" do
    status, = guard.call(env_for(length: nil, input: StringIO.new("x" * 101)))

    expect(status).to eq(413)
  end

  it "stops reading a chunked body as soon as it is over the limit" do
    reads = 0
    input = Object.new
    input.define_singleton_method(:read) { |_n = nil| (reads += 1) <= 1000 ? "x" * 64 * 1024 : nil }

    expect(guard.call(env_for(length: nil, input: input)).first).to eq(413)
    expect(reads).to eq(1)
  end

  it "hands a chunked body under the limit to the app, complete and rewound" do
    status, _headers, body = guard.call(env_for(length: nil, input: StringIO.new("hello")))

    expect([ status, body.first ]).to eq([ 200, "hello" ])
  end

  it "answers 401 when the signature header is absent or blank" do
    expect(guard.call(env_for(signature: nil)).first).to eq(401)
    expect(guard.call(env_for(signature: " ")).first).to eq(401)
  end

  it "does not demand a header when unsigned requests are explicitly allowed (development/test only)" do
    allow(Whatsapp::Signature).to receive(:unsigned_allowed?).and_return(true)

    expect(guard.call(env_for(signature: nil)).first).to eq(200)
  end

  it "answers 400 for a malformed Content-Length" do
    expect(guard.call(env_for(length: "12abc")).first).to eq(400)
    expect(guard.call(env_for(length: "-5")).first).to eq(400)
  end

  it "checks the size before the signature, so an oversized unsigned body is 413" do
    expect(guard.call(env_for(length: 5000, signature: nil)).first).to eq(413)
  end

  it "matches the routes Rails would (trailing slash, format suffix, doubled slash)" do
    %w[/webhooks/whatsapp/ /webhooks/whatsapp.json //webhooks//whatsapp].each do |path|
      env = env_for(length: 5000).merge("PATH_INFO" => path)
      expect(guard.call(env).first).to eq(413)
    end
  end

  it "ignores every other path and method" do
    expect(guard.call(env_for(path: "/admin", length: 5000, signature: nil)).first).to eq(200)
    expect(guard.call(env_for(method: "GET", path: "/webhooks/whatsapp", length: nil, signature: nil)).first).to eq(200)
    expect(guard.call(env_for(path: "/webhooks/whatsapp-other", length: 5000)).first).to eq(200)
  end

  it "logs the refusal reason without payload data" do
    log = capture_log { guard.call(env_for(length: 5000)) }

    expect(log).to include("event=webhook.rejected", "reason=payload_too_large", "stage=guard")
  end

  it "is limited to Meta's documented 3 MB payload and sits before Rack::MethodOverride in the real stack" do
    stack = Rails.application.middleware.map(&:klass)

    expect(described_class::MAX_BODY_BYTES).to eq(3 * 1024 * 1024)
    expect(stack.index(described_class)).to be < stack.index(Rack::MethodOverride)
  end
end

RSpec.describe "WebhookGuard through the app", type: :request do
  it "answers 413 for a body over 3 MiB before any delivery is stored" do
    body = "x" * (WebhookGuard::MAX_BODY_BYTES + 1)

    expect { post_webhook(body) }.not_to change(WebhookDelivery, :count)

    expect(response).to have_http_status(:content_too_large)
  end

  it "answers 413 even for a form-encoded body, which Rack::MethodOverride would otherwise parse" do
    body = "a=" + ("x" * (WebhookGuard::MAX_BODY_BYTES + 1))

    post "/webhooks/whatsapp", params: body, headers: { "Content-Type" => "application/x-www-form-urlencoded", "X-Hub-Signature-256" => "sha256=x" }

    expect(response).to have_http_status(:content_too_large)
  end

  it "answers 401 without a signature header before the controller runs" do
    expect(Webhooks::Ingest).not_to receive(:new)

    post_webhook(meta_fixture("text_greeting"), signature: nil)

    expect(response).to have_http_status(:unauthorized)
  end

  it "still accepts a normal signed delivery" do
    expect { post_webhook(meta_fixture("text_greeting")) }.to change(WebhookDelivery, :count).by(1)

    expect(response).to have_http_status(:ok)
  end

  it "is mirrored by the kamal-proxy request body limit in config/deploy.yml" do
    deploy = YAML.safe_load(ERB.new(Rails.root.join("config/deploy.yml").read).result, aliases: true)

    expect(deploy.dig("proxy", "buffering")).to eq("requests" => true, "max_request_body" => WebhookGuard::MAX_BODY_BYTES)
  end
end
