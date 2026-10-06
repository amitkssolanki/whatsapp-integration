module Backfills
  # V1 stored inbound messages without wa_timestamp and never kept
  # conversations.last_inbound_at, so the 24-hour window of V1 conversations
  # would read as "customer never wrote". This fills both in from data V1 did
  # keep. Called by db/migrate/*_backfill_inbound_timestamps.rb; idempotent, and
  # it never moves a timestamp backwards or overwrites one that is already set.
  #
  #   1. inbound messages with wa_timestamp NULL take Meta's epoch seconds from
  #      raw_payload->>'timestamp' when it is a plain integer.
  #   2. conversations.last_inbound_at = GREATEST(existing, newest inbound
  #      wa_timestamp, or the newest inbound created_at when no message has one).
  #
  # Returns how many rows each step changed.
  class InboundTimestamps
    INBOUND = Message.directions.fetch("inbound")

    MESSAGES_SQL = <<~SQL.squish.freeze
      UPDATE messages
      SET wa_timestamp = to_timestamp((raw_payload->>'timestamp')::bigint) AT TIME ZONE 'UTC'
      WHERE direction = #{INBOUND}
        AND wa_timestamp IS NULL
        AND raw_payload->>'timestamp' ~ '^[0-9]{1,12}$'
    SQL

    CONVERSATIONS_SQL = <<~SQL.squish.freeze
      UPDATE conversations
      SET last_inbound_at = GREATEST(conversations.last_inbound_at, newest.at)
      FROM (
        SELECT conversation_id, COALESCE(MAX(wa_timestamp), MAX(created_at)) AS at
        FROM messages
        WHERE direction = #{INBOUND}
        GROUP BY conversation_id
      ) AS newest
      WHERE newest.conversation_id = conversations.id
        AND conversations.last_inbound_at IS DISTINCT FROM GREATEST(conversations.last_inbound_at, newest.at)
    SQL

    def self.call(connection = ActiveRecord::Base.connection)
      {
        messages: connection.exec_update(MESSAGES_SQL, "Backfill inbound wa_timestamp"),
        conversations: connection.exec_update(CONVERSATIONS_SQL, "Backfill last_inbound_at")
      }
    end
  end
end
