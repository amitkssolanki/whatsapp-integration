require "rails_helper"

# One example group per row of docs/v2/DESIGN.md §5.
RSpec.describe "WhatsApp webhook", type: :request do
  let(:config) { Rails.application.config.whatsapp }

  describe "GET /webhooks/whatsapp (verification handshake)" do
    def verify(mode: "subscribe", token: TEST_VERIFY_TOKEN)
      get "/webhooks/whatsapp", params: { "hub.mode" => mode, "hub.verify_token" => token, "hub.challenge" => "12345" }
    end

    it "echoes the challenge as text when the verify token matches" do
      verify

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("12345")
      expect(response.media_type).to eq("text/plain")
    end

    it "rejects a mismatched token or the wrong mode with 403" do
      verify(token: "wrong")
      expect(response).to have_http_status(:forbidden)

      verify(mode: "unsubscribe")
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects everything with 403 when no verify token is configured, even a blank one" do
      config.verify_token = nil

      verify(token: "")
      expect(response).to have_http_status(:forbidden)

      config.verify_token = ""
      verify(token: "")
      expect(response).to have_http_status(:forbidden)
    end

    it "compares the token in constant time" do
      expect(ActiveSupport::SecurityUtils).to receive(:secure_compare).with("wrong", TEST_VERIFY_TOKEN).and_call_original

      verify(token: "wrong")
    end

    it "stores nothing" do
      expect { verify }.not_to change(WebhookDelivery, :count)
    end
  end

  describe "POST /webhooks/whatsapp" do
    let(:body) { meta_fixture("text_greeting") }

    context "when the signature is missing or invalid" do
      it "answers 401 and stores nothing, for a missing, bogus or wrong-secret signature" do
        [ nil, "sha256=bogus", sign(body, "wrong-secret") ].each do |signature|
          expect { post_webhook(body, signature: signature) }.not_to change(WebhookDelivery, :count)
          expect(response).to have_http_status(:unauthorized)
        end
        expect(enqueued_jobs).to be_empty
      end

      it "fails closed when no app secret is configured" do
        config.app_secret = nil

        post_webhook(body, signature: nil)

        expect(response).to have_http_status(:unauthorized)
        expect(WebhookDelivery.count).to eq(0)
      end

      it "does not accept a signature over a different body" do
        post_webhook(body, signature: sign(body + " "))

        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "with WHATSAPP_ALLOW_UNSIGNED" do
      before do
        config.app_secret = nil
        config.allow_unsigned = true
      end

      it "accepts an unsigned body in development or test" do
        post_webhook(body, signature: nil)

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to be_received
      end

      it "is ignored in a production-like environment: still 401, nothing stored" do
        allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

        post_webhook(body, signature: nil)

        expect(response).to have_http_status(:unauthorized)
        expect(WebhookDelivery.count).to eq(0)
      end
    end

    context "when the body is valid but not JSON" do
      it "answers 200 and stores it as unparseable, without enqueueing" do
        post_webhook("this is not json")

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to have_attributes(status: "unparseable", raw_body: "this is not json", item_counts: {})
        expect(enqueued_jobs).to be_empty
      end

      it "stores a body with invalid UTF-8 or NUL bytes instead of failing, and hashes the original bytes" do
        raw = "\xFF\xFEbroken\u0000".b

        post_webhook(raw)

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to have_attributes(status: "unparseable", body_sha256: Digest::SHA256.hexdigest(raw))
      end

      it "treats JSON that is not an object as an ignored foreign payload" do
        post_webhook("[1, 2, 3]")

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to have_attributes(status: "ignored", outcome: { "reason" => "unexpected_object" })
      end
    end

    context "when the payload is not ours" do
      it "ignores another `object`, recording why, and does not enqueue" do
        other = { object: "instagram", entry: [] }.to_json

        post_webhook(other)

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to have_attributes(status: "ignored", object_type: "instagram", outcome: { "reason" => "unexpected_object" })
        expect(enqueued_jobs).to be_empty
      end

      it "ignores a different phone_number_id when one is configured" do
        config.phone_number_id = "999"

        post_webhook(body)

        expect(response).to have_http_status(:ok)
        expect(WebhookDelivery.sole).to have_attributes(status: "ignored", phone_number_id: "100000000000003", outcome: { "reason" => "phone_number_mismatch" })
        expect(enqueued_jobs).to be_empty
      end

      it "processes a matching phone_number_id" do
        config.phone_number_id = "100000000000003"

        post_webhook(body)

        expect(WebhookDelivery.sole).to be_received
      end

      it "does not check the phone_number_id when none is configured" do
        post_webhook(body)

        expect(WebhookDelivery.sole).to be_received
      end
    end

    context "when the delivery is valid" do
      it "stores the exact bytes and metadata, enqueues the job, and answers 200" do
        expect { post_webhook(body) }.to have_enqueued_job(ProcessWebhookDeliveryJob)

        expect(response).to have_http_status(:ok)
        delivery = WebhookDelivery.sole
        expect(delivery).to have_attributes(
          status: "received",
          raw_body: body,
          body_sha256: Digest::SHA256.hexdigest(body),
          signature_header: sign(body),
          object_type: "whatsapp_business_account",
          phone_number_id: "100000000000003",
          item_counts: { "messages" => 1, "statuses" => 0, "other" => 0 },
          attempts: 0
        )
        expect(delivery.request_id).to be_present
        expect(delivery.received_at).to be_within(5.seconds).of(Time.current)
        expect(enqueued_jobs.sole[:args].first).to eq(delivery.id)
      end

      it "counts statuses and other changes" do
        mixed = JSON.parse(meta_fixture("status_sent"))
        mixed["entry"][0]["changes"] << { "field" => "account_update", "value" => { "event" => "x" } }

        post_webhook(mixed.to_json)

        expect(WebhookDelivery.sole.item_counts).to eq("messages" => 0, "statuses" => 1, "other" => 1)
      end

      it "only stores and enqueues: nothing is processed inside the request" do
        post_webhook(meta_fixture("order"))

        expect([ Message.count, Order.count, Customer.count ]).to eq([ 0, 0, 0 ])
      end

      it "keeps Meta's real duplicate delivery as two rows with the same hash" do
        post_webhook(meta_fixture("status_duplicate_delivery_a"))
        post_webhook(meta_fixture("status_duplicate_delivery_b"))

        expect(WebhookDelivery.count).to eq(2)
        expect(WebhookDelivery.distinct.pluck(:body_sha256).size).to eq(1)
        expect(enqueued_jobs.size).to eq(2)
      end
    end

    context "when storing or enqueueing fails" do
      it "answers 500 so Meta retries, and stores nothing, when the insert fails" do
        allow(WebhookDelivery).to receive(:create!).and_raise(ActiveRecord::ConnectionNotEstablished)

        post_webhook(body)

        expect(response).to have_http_status(:internal_server_error)
        expect(WebhookDelivery.count).to eq(0)
        expect(enqueued_jobs).to be_empty
      end

      it "rolls the delivery back when the enqueue fails, so a stored delivery always has its job" do
        allow(ProcessWebhookDeliveryJob).to receive(:perform_later).and_raise(ActiveRecord::StatementInvalid)

        post_webhook(body)

        expect(response).to have_http_status(:internal_server_error)
        expect(WebhookDelivery.count).to eq(0)
      end
    end

    context "as an endpoint for a non-browser client" do
      it "does not use allow_browser, parameter wrapping or CSRF" do
        expect(Webhooks::WhatsappController.superclass).to eq(ActionController::Base)
        expect(Webhooks::WhatsappController._wrapper_options.format).to be_empty

        post_webhook(body, headers: { "User-Agent" => "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" })

        expect(response).to have_http_status(:ok)
      end

      it "does not log the payload or parsed parameters" do
        log = capture_log { post_webhook(meta_fixture("order")) }

        expect(log).to include("Processing by Webhooks::WhatsappController#receive")
        expect(log).not_to include("Parameters:")
        expect(log).not_to match(/wamid\.|15550100004|Test Customer|MAI-006/)
      end
    end
  end
end
