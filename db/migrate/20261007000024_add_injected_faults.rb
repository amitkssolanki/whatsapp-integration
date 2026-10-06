# A permanent record of every deliberate fault applied to a row
# (docs/operating/PROTOCOL.md). Other labels live in fields that later work
# legitimately overwrites (a successful retry clears error details, a replay
# replaces the outcome), so injected evidence needs its own append-only column.
class AddInjectedFaults < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :injected_faults, :string, array: true, null: false, default: []
    add_column :webhook_deliveries, :injected_faults, :string, array: true, null: false, default: []
  end
end
