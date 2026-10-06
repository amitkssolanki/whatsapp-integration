# Marks rows that are clearly synthetic (created by `demo:seed_integration`, or
# the old "Jordan (demo)" seed customer) so the app can keep them away from Meta
# and out of the real metrics. See docs/operating/PROTOCOL.md.
class AddSyntheticFlags < ActiveRecord::Migration[8.1]
  TABLES = %i[customers products webhook_deliveries].freeze

  def change
    TABLES.each do |table|
      add_column table, :synthetic, :boolean, null: false, default: false
      add_index table, :synthetic
    end

    # The one customer db/seeds.rb used to create. An exact match on both fields
    # only; nothing else is touched.
    reversible do |direction|
      direction.up do
        execute <<~SQL.squish
          UPDATE customers SET synthetic = TRUE
          WHERE whatsapp_number = '+15551234567' AND display_name = 'Jordan (demo)'
        SQL
      end
    end
  end
end
