# Scrubs free text before it is stored or logged. Exception messages from the
# database, Faraday or our own parsing can echo payload fragments: phone
# numbers, Meta message ids, ids embedded in SQL. Anything stored in an error
# column that did not come straight from Meta's error response goes through
# here first (docs/v2/DESIGN.md §11).
module Redact
  DIGIT_RUN = /\d{8,}/
  WAMID = /wamid\.[\w=+\/.\-]+/i

  def self.scrub(text, limit: 300)
    text.to_s.gsub(WAMID, "[wamid]").gsub(DIGIT_RUN, "[#]").truncate(limit)
  end

  # "ClassName: scrubbed message" for an unexpected Ruby exception.
  def self.exception(error, limit: 300)
    scrub("#{error.class.name}: #{error.message}", limit: limit)
  end
end
