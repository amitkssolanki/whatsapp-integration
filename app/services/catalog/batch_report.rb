module Catalog
  # Collects Meta's per-item problems for one batch: the `validation_status`
  # returned when the batch is submitted and the `errors` /
  # `ids_of_invalid_requests` of the finished status entry.
  #
  # An error is attributed to a product only when it names a retailer id we
  # sent. Anything else counts as unattributed, and the status job then refuses
  # to mark any product synced, because we cannot tell which one was rejected.
  class BatchReport
    MESSAGE_LIMIT = 500

    attr_reader :item_errors, :unattributed_count

    def initialize(skus)
      @skus = skus.to_set
      @item_errors = {}
      @unattributed_count = 0
    end

    # [{"retailer_id" => "SKU", "errors" => [{"message" => "..."}], "warnings" => [...]}]
    def absorb_validation_status(entries)
      Array(entries).each do |entry|
        next unless entry.is_a?(Hash)

        messages = Array(entry["errors"])
        messages.each { |error| add(entry["retailer_id"] || entry["id"] || error_id(error), message_of(error)) }
      end
      self
    end

    # {"status" => "finished", "errors" => [{"id" => "SKU", "message" => "..."}],
    #  "errors_total_count" => 1, "ids_of_invalid_requests" => ["SKU"], ...}
    def absorb_status_entry(entry)
      errors = Array(entry["errors"])
      invalid = Array(entry["ids_of_invalid_requests"])

      errors.each { |error| add(error_id(error), message_of(error)) }
      invalid.each do |id|
        add(id, "rejected by Meta (invalid request)") unless id.is_a?(String) && item_errors.key?(id)
      end

      # Meta may list only some errors; if the total is larger and nothing says
      # which items, the rest cannot be attributed.
      missing = entry["errors_total_count"].to_i - errors.size
      @unattributed_count += missing if missing.positive? && invalid.empty?
      self
    end

    # Reloads what an earlier stage stored with #to_result.
    def restore(result)
      Hash(result["item_errors"]).each do |sku, messages|
        Array(messages).each { |message| add(sku, message) }
      end
      @unattributed_count += result["unattributed_count"].to_i
      self
    end

    def to_result
      { "item_errors" => item_errors, "unattributed_count" => unattributed_count }
    end

    def failed_skus
      item_errors.keys
    end

    def unattributed?
      unattributed_count.positive?
    end

    private

    def add(sku, message)
      if sku.is_a?(String) && @skus.include?(sku)
        (@item_errors[sku] ||= []) << message unless @item_errors[sku]&.include?(message)
      else
        @unattributed_count += 1
      end
    end

    def error_id(error)
      error.is_a?(Hash) ? (error["id"] || error["retailer_id"]) : nil
    end

    def message_of(error)
      text = error.is_a?(Hash) ? (error["message"] || error["error_type"] || error.to_json) : error.to_s
      text.to_s.truncate(MESSAGE_LIMIT)
    end
  end
end
