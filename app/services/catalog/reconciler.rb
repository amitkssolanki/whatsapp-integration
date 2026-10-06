module Catalog
  # Compares our products with what Meta returned for the catalog and lists the
  # differences. Pure: it reads, it never writes and never corrects anything.
  #
  # Drift types:
  #   missing_remote        we have the product, Meta does not
  #   extra_remote          Meta has an item we do not (removed or renamed sku, or added by hand)
  #   price_mismatch        parsed remote price/currency differs from ours
  #   price_unparseable     remote price missing or in a shape PriceParser rejects
  #   availability_mismatch remote availability differs from what we would send
  #   name_mismatch         remote name differs from the title we would send
  #   review_not_approved   Meta's review_status is present and is not "approved"
  #
  # Field drift on a product with an unconfirmed local change is tagged
  # `pending_push: true`: it is expected until the next push settles.
  class Reconciler
    def initialize(products:, remote_items:, pending_skus: [])
      @products = products.index_by(&:sku)
      @remote = remote_items.index_by { |item| item["retailer_id"].to_s }.except("")
      @pending = pending_skus.to_set
    end

    def drift
      items = []
      @products.keys.sort.each do |sku|
        product = @products[sku]
        remote = @remote[sku]
        if remote
          items.concat(compare(product, remote))
        else
          items << item("missing_remote", sku)
        end
      end
      (@remote.keys - @products.keys).sort.each { |sku| items << item("extra_remote", sku, remote: @remote[sku]["name"]) }
      items
    end

    def checked
      @products.size
    end

    private

    def compare(product, remote)
      sku = product.sku
      pending = @pending.include?(sku)
      found = []

      found.concat(price_drift(product, remote, pending))

      expected = Fields::AVAILABILITY.fetch(product.availability)
      actual = remote["availability"].to_s.downcase.tr("_", " ").strip
      found << item("availability_mismatch", sku, local: expected, remote: remote["availability"], pending_push: pending) if actual != expected

      title = Fields.for(product)["title"]
      found << item("name_mismatch", sku, local: title, remote: remote["name"], pending_push: pending) if remote["name"].to_s.strip != title

      status = remote["review_status"].to_s.strip
      found << item("review_not_approved", sku, remote: status) if status.present? && status.downcase != "approved"
      found
    end

    def price_drift(product, remote, pending)
      local = Fields.price(product.price_cents, product.currency)
      parsed = PriceParser.parse(remote["price"], currency: remote["currency"])
      return [ item("price_unparseable", product.sku, local: local, remote: remote["price"]) ] unless parsed

      same_amount = parsed.cents == product.price_cents
      same_currency = parsed.currency.nil? || parsed.currency == product.currency.to_s.upcase
      return [] if same_amount && same_currency

      shown = parsed.currency ? Fields.price(parsed.cents, parsed.currency) : Fields.price(parsed.cents, "").strip
      [ item("price_mismatch", product.sku, local: local, remote: shown, pending_push: pending) ]
    end

    def item(type, sku, local: nil, remote: nil, pending_push: false)
      { "type" => type, "sku" => sku, "local" => local, "remote" => remote, "pending_push" => (pending_push || nil) }.compact
    end
  end
end
