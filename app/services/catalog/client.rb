require "faraday"
require "json"

module Catalog
  # Graph API calls for the Meta catalog: push a batch, poll a batch, read
  # products back. Every method returns a Result; none raises for HTTP, API,
  # timeout or configuration problems, so jobs can record the failure and move
  # on. A missing token or CATALOG_ID is a "config" result and makes no request.
  #
  # Only the documented shapes are used (docs/v2/meta-research.md, "Catalog
  # API"); nothing here has been exercised against the live API.
  class Client
    GRAPH_URL = "https://graph.facebook.com".freeze
    PRODUCT_FIELDS = %w[retailer_id name price currency availability review_status].freeze
    PAGE_SIZE = 200
    MAX_PAGES = 100 # guard against a cursor that never ends

    RETRYABLE_CATEGORIES = %w[transient rate_limited].freeze
    RATE_LIMIT_CODES = [ 4, 17, 32, 613, 80_001, 80_004, 130_429 ].freeze
    AUTH_CODES = [ 102, 190 ].freeze
    PERMISSION_CODES = [ 10, *200..299 ].freeze

    Result = Struct.new(:ok, :data, :http_status, :error_code, :error_message, :category, keyword_init: true) do
      def ok? = ok
      def retryable? = RETRYABLE_CATEGORIES.include?(category)
    end

    # The Faraday stack with the production timeouts. `adapter` is the argument
    # list for Faraday's `adapter` (specs pass [:test, stubs]).
    def self.build_connection(adapter: [ Faraday.default_adapter ])
      Faraday.new(url: GRAPH_URL, request: { open_timeout: 3, timeout: 15 }) do |f|
        f.request :url_encoded
        f.adapter(*adapter)
      end
    end

    def initialize(config: Rails.application.config.whatsapp, connection: nil)
      @config = config
      @connection = connection
    end

    # `requests` is an array of {method:, data:} hashes (at most 5000). On
    # success data is {"handles" => [...], "validation_status" => [...]}.
    def items_batch(requests)
      call(:post, "items_batch", {
        item_type: "PRODUCT_ITEM",
        allow_upsert: "true",
        requests: JSON.generate(requests)
      })
    end

    # On success data is the first status entry for the handle, e.g.
    # {"handle" => "...", "status" => "finished", "errors" => [...]}; nil if
    # Meta returned none.
    def batch_status(handle)
      result = call(:get, "check_batch_request_status", { handle: handle, load_ids_of_invalid_requests: "true" })
      return result unless result.ok?

      entries = result.data["data"]
      result.data = entries.is_a?(Array) ? entries.first : nil
      result
    end

    # Reads products back, following paging cursors. retailer_ids: nil reads the
    # whole catalog. On success data is an array of product hashes.
    def products(retailer_ids: nil)
      params = { fields: PRODUCT_FIELDS.join(","), limit: PAGE_SIZE }
      params[:filter] = JSON.generate(retailer_id: { is_any: Array(retailer_ids) }) if retailer_ids

      items = []
      after = nil
      MAX_PAGES.times do
        result = call(:get, "products", after ? params.merge(after: after) : params)
        return result unless result.ok?

        items.concat(Array(result.data["data"]))
        after = result.data.dig("paging", "cursors", "after")
        return ok_result(items, result.http_status) unless result.data.dig("paging", "next") && after
      end
      error_result(nil, "paging did not terminate", "unclassified", code: nil)
    end

    private

    def call(verb, edge, params)
      return config_error unless configured?

      response = connection.public_send(verb, "/#{@config.api_version}/#{@config.catalog_id}/#{edge}", params) do |req|
        req.headers["Authorization"] = "Bearer #{@config.token}"
      end
      interpret(response)
    rescue Faraday::Error => e
      failure = error_result(nil, "#{e.class.name.demodulize}: #{e.message}".truncate(500), "transient")
      AppLog.event("catalog.api_error", edge: edge, category: failure.category, error_class: e.class.name)
      failure
    end

    def configured?
      @config.token.present? && @config.catalog_id.present?
    end

    def config_error
      error_result(nil, "WHATSAPP_TOKEN and CATALOG_ID must both be set", "config")
    end

    def interpret(response)
      body = parse_body(response.body)
      return ok_result(body || {}, response.status) if response.success? && body.is_a?(Hash)

      error = body.is_a?(Hash) ? body["error"] : nil
      error = nil unless error.is_a?(Hash)
      code = error&.dig("code")
      message = error&.dig("message") || "HTTP #{response.status}"
      message = "unparseable response body (HTTP #{response.status})" if response.success?
      category = response.success? ? "invalid_response" : category_for(http_status: response.status, code: code)
      failure = error_result(response.status, message.to_s.truncate(500), category, code: code)
      AppLog.event("catalog.api_error", http_status: response.status, error_code: code, category: category)
      failure
    end

    def parse_body(body)
      return if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def category_for(http_status:, code:)
      code = code&.to_i
      return "rate_limited" if http_status == 429 || RATE_LIMIT_CODES.include?(code)
      return "auth" if AUTH_CODES.include?(code)
      return "permission" if PERMISSION_CODES.include?(code)
      return "transient" if http_status.to_i >= 500
      return "request_invalid" if code == 100

      Whatsapp::ErrorClassifier.category_for(code: code, http_status: http_status)
    end

    def ok_result(data, http_status)
      Result.new(ok: true, data: data, http_status: http_status)
    end

    def error_result(http_status, message, category, code: nil)
      Result.new(ok: false, http_status: http_status, error_code: code, error_message: message, category: category)
    end

    def connection
      @connection ||= self.class.build_connection
    end
  end
end
