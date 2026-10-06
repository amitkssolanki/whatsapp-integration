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
end
