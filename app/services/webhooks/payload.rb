module Webhooks
  # A parsed WhatsApp Cloud API webhook body, as far as ingestion and
  # processing need to look inside it. Tolerant by design: a payload we do not
  # understand is a recorded outcome, never an exception.
  class Payload
    EXPECTED_OBJECT = "whatsapp_business_account".freeze

    def self.parse(raw_body)
      data = JSON.parse(raw_body)
      new(data.is_a?(Hash) ? data : {})
    rescue JSON::ParserError
      nil
    end

    def initialize(data)
      @data = data
    end

    def object_type
      @data["object"] if @data["object"].is_a?(String)
    end

    def expected_object?
      object_type == EXPECTED_OBJECT
    end

    # The first business phone number id the payload mentions.
    def phone_number_id
      values.each do |value|
        id = value.dig("metadata", "phone_number_id") if value["metadata"].is_a?(Hash)
        return id.to_s if id.present?
      end
      nil
    end

    # {"messages"=>n, "statuses"=>n, "other"=>n}; `other` counts changes that
    # carry neither (template updates, account alerts, ...).
    def item_counts
      counts = { "messages" => 0, "statuses" => 0, "other" => 0 }
      changes.each do |change|
        value = change["value"]
        messages = items(value, "messages").size
        statuses = items(value, "statuses").size
        counts["messages"] += messages
        counts["statuses"] += statuses
        counts["other"] += 1 if messages.zero? && statuses.zero?
      end
      counts
    end

    # Yields [kind, value, item] for every message and status, where `value` is
    # the enclosing change value (it holds metadata and contacts).
    def each_item
      changes.each do |change|
        value = change["value"]
        items(value, "messages").each { |item| yield "message", value, item }
        items(value, "statuses").each { |item| yield "status", value, item }
      end
    end

    private

    def entries
      Array(@data["entry"]).select { |entry| entry.is_a?(Hash) }
    end

    def changes
      entries.flat_map { |entry| Array(entry["changes"]) }.select { |change| change.is_a?(Hash) && change["value"].is_a?(Hash) }
    end

    def values
      changes.map { |change| change["value"] }
    end

    def items(value, key)
      return [] unless value.is_a?(Hash)

      Array(value[key]).select { |item| item.is_a?(Hash) }
    end
  end
end
