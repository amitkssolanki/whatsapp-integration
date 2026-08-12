require "csv"

module Catalog
  # Builds a product feed CSV in the format Meta Commerce Manager expects for
  # a Catalog data source feed.
  #
  # https://developers.facebook.com/docs/commerce-platform/catalog/fields
  class FeedGenerator
    AVAILABILITY_LABELS = {
      "in_stock" => "in stock",
      "out_of_stock" => "out of stock",
      "preorder" => "preorder"
    }.freeze

    COLUMNS = %w[id title description availability condition price link image_link brand].freeze

    def initialize(products: Product.includes(:category).order(:sku), base_url:)
      @products = products
      @base_url = base_url
    end

    def to_csv
      CSV.generate(headers: true) do |csv|
        csv << COLUMNS
        @products.each { |product| csv << row_for(product) }
      end
    end

    private

    def row_for(product)
      [
        product.sku,                                     # id (== retailer_id used in WhatsApp order webhooks)
        product.name,                                     # title
        product.description,                               # description
        AVAILABILITY_LABELS.fetch(product.availability),   # availability
        "new",                                              # condition
        format("%.2f %s", product.price, product.currency), # price
        "#{@base_url}/products/#{product.id}",              # link
        product.image_url,                                  # image_link
        "The Local Table"                                   # brand
      ]
    end
  end
end
