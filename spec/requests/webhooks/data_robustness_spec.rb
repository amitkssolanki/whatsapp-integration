require "rails_helper"

RSpec.describe "Webhook data robustness", type: :request do
  describe "bodies PostgreSQL text cannot hold" do
    it "stores the exact bytes of a NUL / invalid UTF-8 body base64 encoded, keeping a scrubbed display copy" do
      raw = "\xFF\xFEbroken\u0000tail".b

      delivery = deliver(raw)

      expect(delivery.reload).to have_attributes(status: "unparseable", body_sha256: Digest::SHA256.hexdigest(raw))
      expect(delivery.raw_body_base64).to eq(Base64.strict_encode64(raw))
      expect(delivery.raw_bytes).to eq(raw)
      expect(delivery.raw_body).to eq("��brokentail")
      expect(delivery.raw_body).to be_valid_encoding
    end

    it "stores a NUL-only body without failing" do
      delivery = deliver("\u0000")

      expect(delivery.reload.raw_body).to eq("")
      expect(delivery.raw_bytes).to eq("\u0000".b)
    end

    it "keeps raw_body as text and leaves raw_body_base64 empty for every ordinary body, including multibyte UTF-8" do
      body = { object: "whatsapp_business_account", entry: [], note: "café \u{1F37D}" }.to_json

      delivery = deliver(body)

      expect(delivery.reload.raw_body_base64).to be_nil
      expect(delivery.raw_body).to eq(body)
      expect(delivery.raw_bytes).to eq(body.b)
      expect(deliver(meta_fixture("text_greeting")).raw_body_base64).to be_nil
    end

    it "accepts an empty signed body instead of answering 500 forever" do
      post_webhook("")

      expect(response).to have_http_status(:ok)
      expect(WebhookDelivery.sole).to have_attributes(raw_body: "", status: "unparseable")
    end

    it "verifies the signature of the stored exact bytes, not of the display copy" do
      raw = "\xFF\xFEbroken\u0000".b
      delivery = deliver(raw)

      expect(delivery.stored_signature_valid?).to be(true)
      expect(Whatsapp::Signature.valid?(delivery.raw_body, delivery.signature_header)).to be(false) # the scrubbed copy never matches
    end

    it "refuses a tampered or corrupt base64 body" do
      delivery = deliver("\xFFbroken".b)

      delivery.update_columns(raw_body_base64: Base64.strict_encode64("\xFFother".b))
      expect(delivery.stored_signature_valid?).to be(false)

      delivery.update_columns(raw_body_base64: "!!! not base64 !!!")
      expect(delivery.stored_signature_valid?).to be(false)
    end

    it "lets a replay re-verify and re-run a delivery whose JSON carries invalid UTF-8 inside a string" do
      json = fixture_json("text_greeting")
      json.dig("entry", 0, "changes", 0, "value", "messages", 0, "text")["body"] = "PLACEHOLDER"
      raw = json.to_json.sub("PLACEHOLDER", "caf\xE9".b.force_encoding(Encoding::BINARY)).b
      delivery = deliver(raw)
      expect(delivery.raw_body_base64).to be_present
      expect(delivery).to be_received

      process_deliveries
      delivery.reload

      expect(delivery).to be_replayable # an item with undecodable text failed or applied; either way it can be replayed
      expect { delivery.replay!(by: "operator") }.not_to raise_error
      expect(delivery.reload).to be_processing
    end

    it "refuses to replay when the stored base64 was edited" do
      raw = fixture_json("text_greeting").to_json.sub("Hi", "H\xFF".b).b
      delivery = deliver(raw)
      process_deliveries
      delivery.reload.update_columns(status: WebhookDelivery.statuses.fetch("failed"), raw_body_base64: Base64.strict_encode64(raw.sub("H\xFF".b, "Hx")))

      expect { delivery.replay!(by: "operator") }.to raise_error(WebhookDelivery::SignatureRefused)
    end
  end

  describe "money columns" do
    it "are bigint, so price x quantity beyond int4 is stored" do
      expect(Order.columns_hash["total_cents"].sql_type).to eq("bigint")
      expect(OrderItem.columns_hash["item_price_cents"].sql_type).to eq("bigint")
      expect(OrderItem.columns_hash["catalog_price_cents"].sql_type).to eq("bigint")
    end

    it "records an absurd cart (price x quantity far above 2^31 cents) instead of failing the item" do
      create_menu
      json = fixture_json("order")
      line = json.dig("entry", 0, "changes", 0, "value", "messages", 0, "order", "product_items", 0)
      line.merge!("item_price" => 999_999.99, "quantity" => 2_000_000_000)
      json.dig("entry", 0, "changes", 0, "value", "messages", 0, "order", "product_items").slice!(1..)

      delivery = deliver_and_process(json.to_json)

      expect(delivery.outcome["items"].map { |item| item["result"] }).to eq([ "applied" ])
      order = Order.sole
      expect(order.total_cents).to eq(99_999_999 * 2_000_000_000)
      expect(order.total_cents).to be > 2**31
      expect(order.order_items.sole.item_price_cents).to eq(99_999_999)
    end

    it "round-trips values above int4 on every widened column" do
      order = create_order(total_cents: 5_000_000_000)
      item = order.order_items.create!(product_retailer_id: "X", quantity: 1, item_price_cents: 4_000_000_000, catalog_price_cents: 3_000_000_000)

      expect(order.reload.total_cents).to eq(5_000_000_000)
      expect(item.reload).to have_attributes(item_price_cents: 4_000_000_000, catalog_price_cents: 3_000_000_000)
    end
  end

  # Review 2 #9: a JSON "\u0000" in any string used to fail the item on every
  # replay, which lost the order.
  describe "NUL characters inside item strings" do
    let!(:menu) { create_menu }

    def with_nul(name)
      json = fixture_json(name)
      yield json.dig("entry", 0, "changes", 0, "value")
      json.to_json # "\u0000" stays an escape in the JSON text
    end

    def outcome_items(delivery) = delivery.outcome["items"].map { |item| item.slice("result", "detail") }

    it "applies an order whose note, product id and profile name carry NUL, replacing it with U+FFFD" do
      body = with_nul("order") do |value|
        value["contacts"][0]["profile"]["name"] = "Zo\u0000e"
        order = value["messages"][0]["order"]
        order["text"] = "no \u0000 onions"
        order["product_items"][0]["product_retailer_id"] = "MAI-006\u0000"
      end
      expect(body).to include("\\u0000")

      delivery = deliver_and_process(body)

      expect(delivery).to be_processed
      expect(outcome_items(delivery)).to eq([ { "result" => "applied", "detail" => "order_id=#{Order.sole.id}; nul_replaced" } ])
      expect(Order.sole.wa_order_note).to eq("no \uFFFD onions")
      expect(Order.sole.order_items.pluck(:product_retailer_id)).to include("MAI-006\uFFFD")
      expect(Customer.sole.display_name).to eq("Zo\uFFFDe")
      inbound = Message.inbound.sole
      expect(inbound.body).to eq("no \uFFFD onions")
      expect(inbound.raw_payload.dig("order", "text")).to eq("no \uFFFD onions")
      expect(inbound.raw_payload.to_json).not_to include("\\u0000")
      expect(Message.outbound.count).to eq(1) # the receipt is queued as usual
    end

    it "applies a text message with NUL in it, and a replay is a clean duplicate (not an error every time)" do
      body = with_nul("text_greeting") { |value| value["messages"][0]["text"]["body"] = "Hi\u0000 there" }

      delivery = deliver_and_process(body)
      expect(delivery.outcome["items"][0]).to include("result" => "applied")
      expect(delivery.outcome["items"][0]["detail"]).to match(/\Areply=\w+; nul_replaced\z/)
      expect(Message.inbound.sole.body).to eq("Hi\uFFFD there")

      delivery.replay!(by: "amit")
      process_deliveries

      expect(outcome_items(delivery.reload).sole).to eq("result" => "duplicate", "detail" => "nul_replaced")
      expect(Message.inbound.count).to eq(1)
    end

    it "does not touch an item without NUL: no flag in the detail" do
      delivery = deliver_and_process(meta_fixture("order"))

      expect(delivery.outcome["items"][0]["detail"]).to eq("order_id=#{Order.sole.id}")
    end

    it "replaces NUL in a failed status's error text and flags the item" do
      create_outbound(wa_message_id: fixture_wa_id("status_sent"), status: :accepted)
      body = fixture_json("status_sent").tap do |json|
        status = json.dig("entry", 0, "changes", 0, "value", "statuses", 0)
        status.merge!("status" => "failed", "errors" => [ { "code" => 131_026, "title" => "Undeliver\u0000able", "message" => "x\u0000y" } ])
      end.to_json

      delivery = deliver_and_process(body)

      expect(delivery.outcome["items"][0]).to include("result" => "applied")
      expect(delivery.outcome["items"][0]["detail"]).to end_with("nul_replaced")
      expect(Message.outbound.sole).to have_attributes(status: "failed", error_title: "Undeliver\uFFFDable")
    end
  end
end
