module Catalog
  # Maps a Product to the `data` hash of an items_batch UPDATE request.
  #
  # The names and formats follow the CSV feed (Catalog::FeedGenerator), which is
  # the Gate B fallback and must keep working unchanged, with three deliberate
  # differences for the batch API:
  #
  # - `availability` is only "in stock" or "out of stock". Meta does not list
  #   "preorder" for batch requests, so a preorder product is sent as
  #   "out of stock": the safe choice, because it stops customers adding an
  #   item we cannot fulfil right now. The feed still sends "preorder".
  # - `price` is built from integer cents, never a float.
  # - `title` is truncated to 100 characters and a blank `description` falls back
  #   to the name, because Meta rejects items without one.
  module Fields
    BRAND = "The Local Table".freeze
    TITLE_LIMIT = 100
    DEFAULT_BASE_URL = "http://localhost:3000".freeze

    AVAILABILITY = {
      "in_stock" => "in stock",
      "out_of_stock" => "out of stock",
      "preorder" => "out of stock"
    }.freeze

    # Product columns that change what Meta would show. Used by Product to
    # decide whether a save is worth a push.
    PRODUCT_ATTRIBUTES = %w[sku name description price_cents currency availability image_url].freeze

    module_function

    # Keys are strings, nils dropped; the digest sorts them, so order is free.
    def for(product, base_url: self.base_url)
      {
        "id" => product.sku, # retailer_id, also what WhatsApp order webhooks carry
        "title" => product.name.to_s.truncate(TITLE_LIMIT),
        "description" => product.description.presence || product.name.to_s,
        "availability" => AVAILABILITY.fetch(product.availability),
        "condition" => "new",
        "price" => price(product.price_cents, product.currency),
        "link" => "#{base_url}/products/#{product.id}",
        "image_link" => product.image_url.presence,
        "brand" => BRAND
      }.compact
    end

    # 1550, "USD" => "15.50 USD". Integer arithmetic only.
    def price(cents, currency)
      whole, fraction = cents.to_i.divmod(100)
      format("%d.%02d %s", whole, fraction, currency)
    end

    # The public origin of the app, from APP_HOST (set in production). Changing
    # it changes every `link`, so every product becomes dirty and is re-pushed.
    def base_url
      host = ENV["APP_HOST"].presence
      host ? "https://#{host}" : DEFAULT_BASE_URL
    end

    # SHA256 of the canonical JSON (keys sorted) of a fields hash.
    def digest(fields)
      Digest::SHA256.hexdigest(JSON.generate(fields.sort.to_h))
    end
  end
end
