class AddUnknownAtToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :unknown_at, :datetime
  end
end
