require "rails_helper"

RSpec.describe Catalog::Client do
  let(:calls) { [] }

  before { configure_catalog! }

  def client_with(&block)
    stub_catalog_http(&block)
    Catalog::Client.new
  end

  describe "#items_batch" do
    let(:requests) { [ { method: "UPDATE", data: { id: "MAI-006", title: "Margherita", price: "15.50 USD" } } ] }

    it "posts a form-encoded batch with item_type, allow_upsert and a JSON requests string" do
      client = client_with do |s|
        s.post("/v26.0/CAT123/items_batch") do |env|
          calls << env
          json_response({ handles: [ "H1" ] })
        end
      end

      result = client.items_batch(requests)

      expect(result).to be_ok
      expect(result.data["handles"]).to eq([ "H1" ])
      env = calls.first
      expect(env.request_headers["Content-Type"]).to start_with("application/x-www-form-urlencoded")
      expect(env.request_headers["Authorization"]).to eq("Bearer #{CatalogStub::TEST_TOKEN}")
      form = Rack::Utils.parse_nested_query(env.request_body)
      expect(form["item_type"]).to eq("PRODUCT_ITEM")
      expect(form["allow_upsert"]).to eq("true")
      expect(JSON.parse(form["requests"])).to eq(JSON.parse(JSON.generate(requests)))
    end

    it "keeps the access token out of the URL" do
      client = client_with { |s| s.post("/v26.0/CAT123/items_batch") { |env| calls << env && json_response({}) } }
      client.items_batch(requests)
      expect(calls.first.url.to_s).not_to include(CatalogStub::TEST_TOKEN)
    end
  end

  describe "#batch_status" do
    it "asks for the handle and the invalid request ids, and returns the first entry" do
      client = client_with do |s|
        s.get("/v26.0/CAT123/check_batch_request_status") do |env|
          calls << env
          json_response({ data: [ { handle: "H1", status: "finished", errors_total_count: 0 } ] })
        end
      end

      result = client.batch_status("H1")

      expect(result).to be_ok
      expect(result.data).to include("status" => "finished")
      expect(calls.first.params).to include("handle" => "H1", "load_ids_of_invalid_requests" => "true")
    end

    it "returns nil data when Meta lists no entry" do
      client = client_with { |s| s.get("/v26.0/CAT123/check_batch_request_status") { json_response({ data: [] }) } }
      expect(client.batch_status("H1").data).to be_nil
    end
  end

  describe "#products" do
    def page(items, after: nil)
      body = { data: items }
      body[:paging] = { cursors: { after: after }, next: "https://graph.facebook.com/next?access_token=SECRET" } if after
      json_response(body)
    end

    it "sends fields and a retailer_id is_any filter" do
      client = client_with do |s|
        s.get("/v26.0/CAT123/products") do |env|
          calls << env
          page([ { retailer_id: "A" } ])
        end
      end

      result = client.products(retailer_ids: %w[A B])

      expect(result).to be_ok
      expect(result.data).to eq([ { "retailer_id" => "A" } ])
      params = calls.first.params
      expect(params["fields"]).to eq("retailer_id,name,price,currency,availability,review_status")
      expect(JSON.parse(params["filter"])).to eq("retailer_id" => { "is_any" => %w[A B] })
    end

    it "reads the whole catalog, with no filter, when no ids are given" do
      client = client_with { |s| s.get("/v26.0/CAT123/products") { |env| calls << env && page([]) } }
      client.products
      expect(calls.first.params).not_to have_key("filter")
    end

    it "follows paging cursors until there is no next page" do
      client = client_with do |s|
        s.get("/v26.0/CAT123/products") do |env|
          calls << env
          case env.params["after"]
          when nil then page([ { retailer_id: "A" } ], after: "c1")
          when "c1" then page([ { retailer_id: "B" } ], after: "c2")
          else page([ { retailer_id: "C" } ])
          end
        end
      end

      result = client.products

      expect(result.data.map { |p| p["retailer_id"] }).to eq(%w[A B C])
      expect(calls.map { |env| env.params["after"] }).to eq([ nil, "c1", "c2" ])
    end

    it "returns the failing page's error if a later page fails" do
      client = client_with do |s|
        s.get("/v26.0/CAT123/products") do |env|
          env.params["after"] ? api_error(code: 1, status: 500) : page([ { retailer_id: "A" } ], after: "c1")
        end
      end

      result = client.products
      expect(result).not_to be_ok
      expect(result.category).to eq("transient")
    end
  end

  describe "failures" do
    def failing(&block)
      client_with { |s| s.post("/v26.0/CAT123/items_batch", &block) }.items_batch([])
    end

    it "never raises and reports a 500 as transient and retryable" do
      result = failing { [ 500, {}, "Internal error" ] }
      expect(result).not_to be_ok
      expect(result.http_status).to eq(500)
      expect(result.category).to eq("transient")
      expect(result).to be_retryable
    end

    {
      [ 429, nil ] => "rate_limited",
      [ 400, 4 ] => "rate_limited",
      [ 400, 80_004 ] => "rate_limited",
      [ 401, 190 ] => "auth",
      [ 403, 200 ] => "permission",
      [ 403, 10 ] => "permission",
      [ 400, 100 ] => "request_invalid",
      [ 400, 131_009 ] => "request_invalid", # via Whatsapp::ErrorClassifier
      [ 400, 999_999 ] => "unclassified"
    }.each do |(status, code), category|
      it "classifies HTTP #{status} code #{code.inspect} as #{category}" do
        result = failing { json_response({ error: { code: code, message: "nope" } }, status: status) }
        expect(result.category).to eq(category)
        expect(result.error_code).to eq(code)
        expect(result.error_message).to eq("nope")
      end
    end

    it "treats permission and auth failures as not retryable" do
      expect(failing { api_error(code: 190, status: 401) }).not_to be_retryable
    end

    it "reports a timeout as transient" do
      result = failing { raise Faraday::TimeoutError, "execution expired" }
      expect(result).not_to be_ok
      expect(result.category).to eq("transient")
      expect(result.error_message).to include("TimeoutError")
    end

    it "reports a connection failure as transient" do
      result = failing { raise Faraday::ConnectionFailed, "no route" }
      expect(result.category).to eq("transient")
    end

    it "flags a 200 with an unparseable body" do
      result = failing { [ 200, {}, "<html>" ] }
      expect(result).not_to be_ok
      expect(result.category).to eq("invalid_response")
    end

    it "returns a config error without any HTTP when the token or catalog id is missing" do
      [ { token: nil }, { catalog_id: nil }, { token: "", catalog_id: "" } ].each do |missing|
        configure_catalog!(**missing)
        # An empty stub set raises NotFound on any request, which would fail this example.
        client = client_with { |_s| }
        result = client.items_batch([])
        expect(result).not_to be_ok
        expect(result.category).to eq("config")
        expect(client.batch_status("H").category).to eq("config")
        expect(client.products.category).to eq("config")
      end
    end
  end

  it "builds the connection with the documented timeouts" do
    connection = described_class.build_connection
    expect(connection.options.open_timeout).to eq(3)
    expect(connection.options.timeout).to eq(15)
    expect(connection.url_prefix.to_s).to eq("https://graph.facebook.com/")
  end
end
