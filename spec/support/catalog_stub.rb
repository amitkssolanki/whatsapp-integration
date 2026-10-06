# Helpers for catalog specs: a configured token/catalog id and a Catalog::Client
# whose HTTP goes to Faraday's in-memory test adapter, so no spec can reach
# graph.facebook.com. An unstubbed request raises Stubs::NotFound.
module CatalogStub
  TEST_CATALOG_ID = "CAT123".freeze
  TEST_TOKEN = "test-catalog-token".freeze

  def configure_catalog!(token: TEST_TOKEN, catalog_id: TEST_CATALOG_ID, sync: false)
    config = Rails.application.config.whatsapp
    config.token = token
    config.catalog_id = catalog_id
    config.catalog_sync_enabled = sync
  end

  # Builds the client and makes Catalog::Client.new return it, so jobs and
  # services use the stubs. Yields the Stubs for routes:
  #   stub_catalog_http { |s| s.post("/v26.0/CAT123/items_batch") { [200, {}, "{}"] } }
  def stub_catalog_http(&block)
    stubs = Faraday::Adapter::Test::Stubs.new(&block)
    connection = Catalog::Client.build_connection(adapter: [ :test, stubs ])
    allow(Catalog::Client).to receive(:new).and_call_original # drop any earlier stub before building
    client = Catalog::Client.new(connection: connection)
    allow(Catalog::Client).to receive(:new).and_return(client)
    client
  end

  def json_response(body, status: 200)
    [ status, { "Content-Type" => "application/json" }, JSON.generate(body) ]
  end

  def api_error(code:, message: "boom", status: 400)
    json_response({ error: { message: message, type: "OAuthException", code: code } }, status: status)
  end
end

RSpec.configure { |config| config.include CatalogStub }
