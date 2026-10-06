require "bigdecimal"

module Orders
  # Turns the `order` object of an inbound WhatsApp message into an Order and
  # its OrderItems, recording what looks wrong instead of refusing it
  # (docs/v2/DESIGN.md §9). The customer already sent the cart and was shown
  # prices, so an order is always recorded and an operator decides.
  #
  # Rules: honor the price the customer saw, never auto-reject, no quantity
  # caps. Issues set review_status: needs_review.
  class Builder
    # The payload has no `order` object (or it is not one): nothing sensible to
    # record, so the item fails and stays replayable.
    class MissingOrder < StandardError; end

    MAX_QUANTITY = 2**31 - 1 # larger than the integer column; certainly not a real cart

    def initialize(customer:, source_message_id:, order_payload:, config: Rails.application.config.whatsapp)
      @customer = customer
      @source_message_id = source_message_id
      @order_payload = order_payload
      @config = config
      @issues = []
    end

    def call
      raise MissingOrder, "order object missing" unless @order_payload.is_a?(Hash)

      lines = build_lines
      check_catalog
      issue("malformed", nil, "at least one valid product line", 0) if lines.empty?

      Order.transaction do
        order = Order.create!(
          customer: @customer,
          source_message_id: @source_message_id,
          catalog_id: @order_payload["catalog_id"],
          wa_order_note: @order_payload["text"].presence,
          currency: lines.first&.dig(:currency) || "USD",
          total_cents: lines.sum { |line| line[:item_price_cents] * line[:quantity] },
          review_status: @issues.empty? ? :clear : :needs_review,
          validation_issues: @issues
        )
        lines.each { |line| order.order_items.create!(line) }
        order
      end
    end

    private

    def build_lines
      items = Array(@order_payload["product_items"])
      products = catalog_products.where(sku: items.filter_map { |item| item["product_retailer_id"].to_s.presence if item.is_a?(Hash) }).index_by(&:sku)

      items.filter_map { |item| build_line(item, products) }
    end

    def build_line(item, products)
      unless item.is_a?(Hash)
        issue("malformed", nil, "product item object", item.class.name)
        return
      end

      sku = item["product_retailer_id"].to_s
      quantity = parse_quantity(item["quantity"])
      price_cents = parse_price_cents(item["item_price"])

      if sku.blank?
        issue("unknown_sku", nil, "product_retailer_id", item["product_retailer_id"])
        return
      end
      if quantity.nil?
        issue("invalid_quantity", sku, "integer >= 1", item["quantity"])
        return
      end
      if price_cents.nil?
        issue("invalid_price", sku, "non-negative decimal", item["item_price"])
        return
      end

      product = products[sku]
      currency = item["currency"].presence&.to_s&.upcase
      check_product(product, sku, price_cents, currency)

      {
        product: product,
        product_retailer_id: sku,
        quantity: quantity,
        item_price_cents: price_cents,
        catalog_price_cents: product&.price_cents,
        currency: currency || product&.currency || "USD"
      }
    end

    # A synthetic product exists only for synthetic customers; to everyone else
    # its SKU is unknown (it is not in the real catalog).
    def catalog_products
      @customer.synthetic? ? Product.all : Product.non_synthetic
    end

    def check_product(product, sku, price_cents, currency)
      return issue("unknown_sku", sku, "a product in the catalog", sku) unless product

      issue("price_mismatch", sku, product.price_cents, price_cents) if product.price_cents != price_cents
      issue("unavailable", sku, "in_stock", product.availability) if product.out_of_stock?
      issue("currency_mismatch", sku, product.currency, currency) if currency && currency != product.currency
    end

    def check_catalog
      configured = @config.catalog_id.to_s
      return if configured.blank?

      actual = @order_payload["catalog_id"]
      issue("unknown_catalog", nil, configured, actual) if actual.to_s != configured
    end

    # Meta sends integers; older samples and hand-made payloads send strings.
    def parse_quantity(value)
      number = case value
      when Integer then value
      when String then value.strip.match?(/\A\d+\z/) ? value.strip.to_i : nil
      end
      number if number && number.between?(1, MAX_QUANTITY)
    end

    # Never through Float: 15.5 and "15.50" must both be exactly 1550 cents.
    def parse_price_cents(value)
      return nil if value.nil? || value == true || value == false

      price = BigDecimal(value.to_s, exception: false)
      return nil unless price&.finite? && price >= 0

      (price * 100).round
    end

    def issue(code, sku, expected, actual)
      @issues << { "code" => code, "sku" => sku, "expected" => expected, "actual" => actual }
    end
  end
end
