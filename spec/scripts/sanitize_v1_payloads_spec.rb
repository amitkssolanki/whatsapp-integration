require "rails_helper"
require "open3"
require "tmpdir"

# script/sanitize_v1_payloads.rb is how new real payload shapes get into the
# repo (docs/operating/PROTOCOL.md), so it must not let free text typed by a
# person through (review 2 #10d).
RSpec.describe "script/sanitize_v1_payloads.rb" do
  let(:script) { Rails.root.join("script/sanitize_v1_payloads.rb").to_s }

  def post_line(payload, at)
    [ %(Started POST "/webhooks/whatsapp" for 203.0.113.7 at 2026-08-08 10:00:0#{at} +0000),
      %(  Parameters: #{payload.inspect}), "" ]
  end

  def envelope(contacts:, message:)
    { "object" => "whatsapp_business_account",
      "entry" => [ { "id" => "123456789012345", "changes" => [ { "field" => "messages", "value" => {
        "messaging_product" => "whatsapp", "metadata" => { "display_phone_number" => "15551234567", "phone_number_id" => "987654321098765" },
        "contacts" => contacts, "messages" => [ message ] } } ] } ] }
  end

  let(:log) do
    order = envelope(
      contacts: [ { "profile" => { "name" => "Ana Lopez", "username" => "ana_lopez_93" }, "wa_id" => "15551230001", "user_id" => "US.9999999999999999" } ],
      message: { "from" => "15551230001", "id" => "wamid.HBgLREALREAL", "timestamp" => "1786204851", "type" => "order",
                 "order" => { "catalog_id" => "555555555555555", "text" => "for Ana, 12 Elm St, gate code 4411",
                              "product_items" => [ { "product_retailer_id" => "MAI-006", "quantity" => 1, "item_price" => 15.5, "currency" => "USD" } ] } }
    )
    quiet_order = envelope(
      contacts: [ { "profile" => { "name" => "Ben" }, "wa_id" => "15551230002" } ],
      message: { "from" => "15551230002", "id" => "wamid.HBgLOTHER", "timestamp" => "1786204852", "type" => "order",
                 "order" => { "catalog_id" => "555555555555555", "text" => "", "product_items" => [] } }
    )
    greeting = envelope(
      contacts: [ { "profile" => { "name" => "Ana Lopez" }, "wa_id" => "15551230001" } ],
      message: { "from" => "15551230001", "id" => "wamid.HBgLGREET", "timestamp" => "1786204853", "type" => "text", "text" => { "body" => "Hi" } }
    )
    [ order, quiet_order, greeting ].each_with_index.flat_map { |payload, i| post_line(payload, i) }.join("\n")
  end

  it "replaces order notes and usernames with synthetic values, keeps the empty note, and leaks nothing" do
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "development.log")
      File.write(log_path, log)
      out = File.join(dir, "out")

      stdout, stderr, status = Open3.capture3("ruby", script, log_path, out)
      expect(status).to be_success, "#{stdout}\n#{stderr}"

      written = Dir[File.join(out, "*.json")].map { |file| File.read(file) }.join("\n")
      %w[Ana Lopez ana_lopez_93 Elm gate 4411 15551230001 US.9999999999999999].each { |secret| expect(written).not_to include(secret), secret }
      expect(JSON.parse(File.read(File.join(out, "order.json"))).dig("entry", 0, "changes", 0, "value", "messages", 0, "order", "text")).to match(/\Atest order note \d+\z/)
      expect(written).to include("test_user_1")
    end
  end

  it "keeps the empty note verbatim" do
    Dir.mktmpdir do |dir|
      only_quiet = log.split("\n\n").reject { |chunk| chunk.include?("Elm St") }.join("\n\n")
      File.write(File.join(dir, "development.log"), only_quiet)

      _stdout, stderr, status = Open3.capture3("ruby", script, File.join(dir, "development.log"), File.join(dir, "out"))

      expect(status).to be_success, stderr
      expect(JSON.parse(File.read(File.join(dir, "out", "order.json"))).dig("entry", 0, "changes", 0, "value", "messages", 0, "order", "text")).to eq("")
    end
  end
end
