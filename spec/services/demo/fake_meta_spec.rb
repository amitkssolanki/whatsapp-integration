require "rails_helper"

RSpec.describe Demo::FakeMeta do
  def post_message(meta)
    connection = Faraday.new(url: "https://graph.facebook.com") { |f| f.adapter(*meta.adapter) }
    JSON.parse(connection.post("/v26.0/1/messages", "{}").body)
  end

  it "answers with synthetic ids that cannot be mistaken for Meta's: sim.out.N by default" do
    meta = described_class.new

    expect(post_message(meta).dig("messages", 0, "id")).to eq("sim.out.1")
    expect(post_message(meta).dig("messages", 0, "id")).to eq("sim.out.2")
    expect(meta.calls).to eq(2)
  end

  it "keeps WhatsApp and catalog requests apart, and answers catalog calls with an empty success" do
    meta = described_class.new
    connection = Faraday.new(url: "https://graph.facebook.com") { |f| f.adapter(*meta.catalog_adapter) }

    expect(JSON.parse(connection.get("/v26.0/CAT/products").body)).to include("data" => [])
    expect(meta.catalog_requests.size).to eq(1)
    expect(meta.calls).to eq(0)
    expect(meta.owns_catalog?(meta.catalog_adapter)).to be(true)
    expect(meta.owns_whatsapp?(meta.catalog_adapter)).to be(false)
    expect(meta.owns?(graph.adapter)).to be(false)
  end
end
