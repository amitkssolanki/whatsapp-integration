require "rails_helper"

RSpec.describe Whatsapp::ErrorClassifier do
  # DESIGN §7, row by row.
  taxonomy = {
    "request_invalid" => [ 100, 131008, 131009, 131021, 131051, 131053, 135000 ],
    "recipient_not_allowed" => [ 131030 ],
    "recipient_undeliverable" => [ 131026, 131049, 131050, 130472 ],
    "window_closed" => [ 131047 ],
    "auth_config" => [ 0, 190, 10, *200..299, 131005 ],
    "account_config" => [ 133010, 133000, 131042, 131045 ],
    "account_quality" => [ 131048, 368, 131031, 131064 ],
    "rate_limited" => [ 4, 80007, 130429, 131056 ],
    "transient_platform" => [ 1, 2, 131000, 131016, 131057, 133004, 2494100 ]
  }

  describe ".classify by code" do
    taxonomy.each do |category, codes|
      codes.each do |code|
        it "maps #{code} to #{category}" do
          expect(described_class.classify(code: code).category).to eq(category)
          expect(described_class.category_for(code: code)).to eq(category)
        end
      end
    end

    it "accepts the code as a numeric string (Meta's JSON and our stored column differ)" do
      expect(described_class.category_for(code: "131047")).to eq("window_closed")
    end

    it "marks only rate_limited and transient_platform codes retryable, and none ambiguous" do
      taxonomy.each do |category, codes|
        result = described_class.classify(code: codes.first)
        expect(result.retryable).to eq(%w[rate_limited transient_platform].include?(category)), category
        expect(result.ambiguous).to be(false)
      end
    end

    it "leaves unknown codes unclassified, whatever the HTTP status says" do
      [ 999_999, 131_999, 17 ].each do |code|
        expect(described_class.classify(code: code, http_status: 500)).to have_attributes(category: "unclassified", retryable: false)
        expect(described_class.classify(code: code, http_status: 401).category).to eq("unclassified")
      end
    end

    it "lets the code win over a contradicting HTTP status" do
      expect(described_class.classify(code: 131047, http_status: 500).category).to eq("window_closed")
      expect(described_class.classify(code: 131009, http_status: 429).category).to eq("request_invalid")
    end

    it "keeps the three codes real V1 traffic produced" do
      expect(described_class.category_for(code: 131009)).to eq("request_invalid")
      expect(described_class.category_for(code: 131030)).to eq("recipient_not_allowed")
      expect(described_class.category_for(code: 133010)).to eq("account_config")
    end
  end

  describe "HTTP status fallback (only when there is no code)" do
    {
      401 => "auth_config", 403 => "auth_config", 429 => "rate_limited",
      500 => "transient_platform", 502 => "transient_platform", 503 => "transient_platform", 599 => "transient_platform",
      400 => "unclassified", 404 => "unclassified", 408 => "unclassified", 200 => "unclassified", nil => "unclassified"
    }.each do |status, category|
      it "maps HTTP #{status.inspect} without a code to #{category}" do
        expect(described_class.classify(code: nil, http_status: status).category).to eq(category)
      end
    end

    it "marks the retryable fallbacks retryable" do
      expect(described_class.classify(http_status: 429)).to have_attributes(retryable: true, ambiguous: false)
      expect(described_class.classify(http_status: 503)).to have_attributes(retryable: true)
      expect(described_class.classify(http_status: 401)).to have_attributes(retryable: false)
    end
  end

  describe ".classify_exception" do
    it "treats a failure to connect as transient_network: the request never left" do
      [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL, SocketError, Net::OpenTimeout ].each do |klass|
        result = described_class.classify_exception(Faraday::ConnectionFailed.new(klass.new("x")))
        expect(result).to have_attributes(category: "transient_network", retryable: true, ambiguous: false), "expected #{klass} to be transient_network"
      end
    end

    it "treats a reset after the request may have been sent as ambiguous, even though Faraday calls it ConnectionFailed" do
      [ Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED, IOError, Net::ProtocolError, Net::HTTPBadResponse ].each do |klass|
        result = described_class.classify_exception(Faraday::ConnectionFailed.new(klass.new("x")))
        expect(result).to have_attributes(category: "ambiguous", retryable: false, ambiguous: true), "expected #{klass} to be ambiguous"
      end
    end

    it "treats a ConnectionFailed with no wrapped exception as ambiguous (nothing proves it never left)" do
      expect(described_class.classify_exception(Faraday::ConnectionFailed.new("boom")).category).to eq("ambiguous")
    end

    it "treats read and write timeouts as ambiguous" do
      [ Net::ReadTimeout.new, Net::WriteTimeout.new, Errno::ETIMEDOUT.new ].each do |inner|
        expect(described_class.classify_exception(Faraday::TimeoutError.new(inner))).to have_attributes(category: "ambiguous", ambiguous: true, retryable: false)
      end
    end

    it "treats a TLS handshake failure as transient_network" do
      expect(described_class.classify_exception(Faraday::SSLError.new(OpenSSL::SSL::SSLError.new("x"))).category).to eq("transient_network")
    end

    it "treats any other Faraday failure after the request was handed over as ambiguous" do
      [ Faraday::NilStatusError.new({}), Faraday::ParsingError.new("x"), Faraday::Error.new("x") ].each do |error|
        expect(described_class.classify_exception(error).category).to eq("ambiguous")
      end
    end
  end

  # Pins the adapter behaviour the classifier relies on. Source of truth:
  # faraday-net_http 3.4.4, lib/faraday/adapter/net_http.rb, Adapter::NetHttp#call
  # (NET_HTTP_EXCEPTIONS -> ConnectionFailed, Timeout::Error -> TimeoutError).
  # Net::HTTP#start is stubbed to raise, so no socket is ever opened.
  describe "Faraday 2's net_http adapter" do
    def raised_by_adapter(exception)
      allow_any_instance_of(Net::HTTP).to receive(:start).and_raise(exception)
      Faraday.new(url: "https://graph.example.test") { |f| f.adapter :net_http }.post("/x")
      nil
    rescue Faraday::Error => e
      e
    end

    [
      [ Net::OpenTimeout, Faraday::ConnectionFailed, "transient_network" ],
      [ Errno::ECONNREFUSED, Faraday::ConnectionFailed, "transient_network" ],
      [ SocketError, Faraday::ConnectionFailed, "transient_network" ],
      [ Errno::ECONNRESET, Faraday::ConnectionFailed, "ambiguous" ],
      [ Errno::EPIPE, Faraday::ConnectionFailed, "ambiguous" ],
      [ Net::ReadTimeout, Faraday::TimeoutError, "ambiguous" ],
      [ Net::WriteTimeout, Faraday::TimeoutError, "ambiguous" ]
    ].each do |raw, faraday_class, category|
      it "surfaces #{raw} as #{faraday_class}, which we classify as #{category}" do
        error = raised_by_adapter(raw.new("x"))

        expect(error).to be_instance_of(faraday_class)
        expect(error.wrapped_exception).to be_a(raw)
        expect(described_class.classify_exception(error).category).to eq(category)
      end
    end

    it "does not make Net::OpenTimeout a TimeoutError even though it is a Timeout::Error" do
      expect(Net::OpenTimeout.ancestors).to include(Timeout::Error)
      expect(raised_by_adapter(Net::OpenTimeout.new)).not_to be_a(Faraday::TimeoutError)
    end
  end
end
