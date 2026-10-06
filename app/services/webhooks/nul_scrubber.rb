module Webhooks
  # PostgreSQL text and jsonb cannot hold NUL ("\u0000"). A JSON payload can
  # carry one in any string (a message text, an order note, a profile name, a
  # product field), and inserting it would fail the item on every replay, so an
  # order could be lost. The item is cleaned before anything is written: every
  # NUL in every string (keys too) becomes U+FFFD, and the item's outcome
  # records `nul_replaced`.
  module NulScrubber
    NUL = "\u0000".freeze
    REPLACEMENT = "�".freeze
    DETAIL = "nul_replaced".freeze

    module_function

    # Returns [clean copy, whether anything was replaced]. The input is not modified.
    def call(value)
      changed = false
      clean = walk(value) { changed = true }
      [ clean, changed ]
    end

    # The detail text of an item result, with the flag appended when needed.
    def detail(detail, changed)
      return detail unless changed

      [ detail.presence, DETAIL ].compact.join("; ")
    end

    def walk(value, &replaced)
      case value
      when String then value.include?(NUL) ? value.tap { replaced.call }.gsub(NUL, REPLACEMENT) : value
      when Hash then value.to_h { |key, inner| [ walk(key, &replaced), walk(inner, &replaced) ] }
      when Array then value.map { |inner| walk(inner, &replaced) }
      else value
      end
    end
    private_class_method :walk
  end
end
