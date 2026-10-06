require "faraday"
require "net/http"

module Whatsapp
  # Maps a WhatsApp Cloud API error to a category that decides what happens
  # next (retry, resend after a fix, give up, or "we cannot know"). The same
  # table applies to a synchronous /messages error and to `statuses[].errors[]`
  # on a failed-status webhook. docs/v2/DESIGN.md §7 is the contract; the
  # evidence behind each row is in docs/v2/meta-research.md.
  #
  # Rules:
  # * Classify by Meta's `code` first. HTTP status is only a fallback when the
  #   response carried no code at all (a code we do not know is `unclassified`,
  #   whatever the HTTP status, so taxonomy gaps stay visible).
  # * Transport failures are classified by what they prove about the request:
  #   if it provably never left, retrying is safe (`transient_network`); if it
  #   may have reached Meta, resending could duplicate a customer message, so
  #   the outcome is `ambiguous` and the message becomes `unknown`.
  class ErrorClassifier
    # What to do about an error.
    Classification = Data.define(:category, :retryable, :ambiguous)

    # Codes marked (V1) were received in real V1 traffic (spec/fixtures/meta/v1);
    # everything else comes from Meta's documentation only.
    CODE_CATEGORIES = {
      "request_invalid" => [
        100,
        131008,
        131009, # (V1) catalog_message without thumbnail_product_retailer_id
        131021,
        131051,
        131053,
        135000
      ],
      "recipient_not_allowed" => [
        131030 # (V1) test-number allow-list; no longer on Meta's error page
      ],
      "recipient_undeliverable" => [ 131026, 131049, 131050, 130472 ],
      "window_closed" => [ 131047 ],
      "auth_config" => [ 0, 190, 10, *200..299, 131005 ],
      "account_config" => [
        133010, # (V1) "Account not registered"
        133000,
        131042, # billing
        131045
      ],
      "account_quality" => [ 131048, 368, 131031, 131064 ],
      "rate_limited" => [ 4, 80007, 130429, 131056 ],
      "transient_platform" => [ 1, 2, 131000, 131016, 131057, 133004, 2494100 ]
    }.freeze

    CATEGORY_BY_CODE = CODE_CATEGORIES.flat_map { |category, codes| codes.map { |code| [ code, category ] } }.to_h.freeze

    RETRYABLE = %w[rate_limited transient_platform transient_network].freeze

    UNCLASSIFIED = "unclassified".freeze
    AMBIGUOUS = "ambiguous".freeze

    # Exceptions that, wrapped in Faraday::ConnectionFailed, prove the request
    # never reached Meta: the connection could not be established.
    NEVER_SENT = [
      Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
      SocketError, # DNS failure (getaddrinfo)
      Net::OpenTimeout
    ].freeze

    # How Faraday 2's net_http adapter surfaces transport errors (verified in
    # faraday-net_http 3.4.4, lib/faraday/adapter/net_http.rb, `#call`, and
    # pinned by spec/services/whatsapp/error_classifier_spec.rb):
    #
    #   Net::OpenTimeout, ECONNREFUSED, SocketError (and the other
    #   NET_HTTP_EXCEPTIONS) -> Faraday::ConnectionFailed, wrapping the original
    #   OpenSSL::SSL::SSLError (handshake OR mid-response)   -> Faraday::SSLError
    #   Net::ReadTimeout / Net::WriteTimeout (Timeout::Error), ETIMEDOUT
    #                                                        -> Faraday::TimeoutError
    #
    # ConnectionFailed is NOT proof the request never left: the same class wraps
    # ECONNRESET, EPIPE, IOError and protocol errors, all of which can happen
    # after Meta received (and possibly acted on) the request. Hence the
    # `wrapped_exception` check: only a whitelist of "could not even connect"
    # errors is retryable; everything else is ambiguous.
    def self.classify_exception(error)
      if error.is_a?(Faraday::ConnectionFailed)
        never_sent = NEVER_SENT.any? { |klass| error.wrapped_exception.is_a?(klass) }
        return build(never_sent ? "transient_network" : AMBIGUOUS)
      end
      return build(handshake_failure?(error) ? "transient_network" : AMBIGUOUS) if error.is_a?(Faraday::SSLError)

      # TimeoutError (read/write/ETIMEDOUT), NilStatusError, ParsingError, anything
      # else Faraday raises after the request was handed to the socket.
      build(AMBIGUOUS)
    end

    # faraday-net_http maps EVERY OpenSSL::SSL::SSLError to Faraday::SSLError,
    # wherever it was raised, including while reading the response (OpenSSL 3:
    # "SSL_read: unexpected eof while reading" when the peer closes mid-response).
    # Only an error that names a handshake / verification failure proves no
    # request bytes were sent; every other SSLError is as ambiguous as ECONNRESET.
    HANDSHAKE_FAILURE = /certificate verify failed|wrong version number|handshake failure|no protocols available/i

    def self.handshake_failure?(error)
      message = error.wrapped_exception&.message.presence || error.message
      message.to_s.match?(HANDSHAKE_FAILURE)
    end
    private_class_method :handshake_failure?

    # Classification for an API error: Meta's `code` (an Integer or numeric
    # string) and, only when there is no code, the HTTP status.
    def self.classify(code: nil, http_status: nil)
      build(category_for(code: code, http_status: http_status))
    end

    def self.category_for(code: nil, http_status: nil)
      number = Integer(code.to_s, exception: false)
      return CATEGORY_BY_CODE.fetch(number, UNCLASSIFIED) if number

      http_fallback(http_status.to_i)
    end

    def self.retryable?(category) = RETRYABLE.include?(category.to_s)

    def self.http_fallback(status)
      case status
      when 401, 403 then "auth_config"
      when 429 then "rate_limited"
      when 500..599 then "transient_platform"
      else UNCLASSIFIED
      end
    end
    private_class_method :http_fallback

    def self.build(category)
      Classification.new(category: category, retryable: retryable?(category), ambiguous: category == AMBIGUOUS)
    end
    private_class_method :build
  end
end
