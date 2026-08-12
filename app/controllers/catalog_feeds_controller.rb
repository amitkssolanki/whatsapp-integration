# Public, unauthenticated endpoint that Meta Commerce Manager polls to sync
# the WhatsApp Catalog. Must stay reachable without login.
class CatalogFeedsController < ApplicationController
  skip_forgery_protection

  def show
    csv = Catalog::FeedGenerator.new(base_url: request.base_url).to_csv
    send_data csv, type: "text/csv", filename: "the-local-table-feed.csv", disposition: "inline"
  end
end
