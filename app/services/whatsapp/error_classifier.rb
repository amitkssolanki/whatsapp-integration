module Whatsapp
  # Maps a WhatsApp Cloud API error to a category that decides what happens
  # next (retry, resend after a fix, give up). Applies to both a synchronous
  # /messages error and `statuses[].errors[]` on a failed-status webhook.
  #
  # Only codes actually observed in V1 traffic are mapped so far; everything
  # else is deliberately "unclassified" so taxonomy gaps are visible. The full
  # table lives in docs/v2/DESIGN.md §7.
  class ErrorClassifier
    OBSERVED_CODES = {
      131009 => "request_invalid",
      131030 => "recipient_not_allowed",
      133010 => "account_config"
    }.freeze

    UNCLASSIFIED = "unclassified".freeze

    def self.category_for(code:, http_status: nil)
      OBSERVED_CODES.fetch(code&.to_i, UNCLASSIFIED)
    end
  end
end
