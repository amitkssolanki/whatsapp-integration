# V1 data fix: see Backfills::InboundTimestamps. Data only, so down is a no-op.
class BackfillInboundTimestamps < ActiveRecord::Migration[8.1]
  def up
    result = Backfills::InboundTimestamps.call(connection)
    say "inbound wa_timestamp filled on #{result[:messages]} messages, last_inbound_at set on #{result[:conversations]} conversations"
  end

  def down
    # Nothing to undo: the filled values are the true ones.
  end
end
