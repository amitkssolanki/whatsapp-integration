# Ops::Purge anonymises people's data at the end of the operating period. These
# columns record that it happened (so a purge is idempotent and operator actions
# can refuse a purged row), and `purged_had_phone` keeps the one aggregate the
# report derives from a phone number ("customers without a phone") stable.
class AddPurgeMarkers < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :purged_at, :datetime
    add_column :customers, :purged_at, :datetime
    add_column :customers, :purged_had_phone, :boolean
  end
end
