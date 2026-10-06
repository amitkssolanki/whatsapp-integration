class AddPurgedAtToWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    add_column :webhook_deliveries, :purged_at, :datetime
  end
end
