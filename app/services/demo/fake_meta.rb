require "net/http"

module Demo
  # An in-process stand-in for graph.facebook.com for the demo simulator: a
  # Faraday test adapter, so a request to it is answered here and can never
  # leave the process, whatever token is configured. It answers 200 with a
  # synthetic message id unless told to fail the next call.
  class FakeMeta
    # What a message id from this fake looks like, e.g. "sim.out.3". It is
    # deliberately not "wamid." so a fake id can never be mistaken for one of
    # Meta's.
    DEFAULT_PREFIX = "sim.out".freeze

    attr_reader :requests, :catalog_requests

    # `prefix` makes the synthetic message ids unique per run.
    def initialize(prefix: DEFAULT_PREFIX)
      @prefix = prefix
      @script = []
      @requests = []
      @catalog_requests = []
      @sent = 0
    end

    # The next call gets this HTTP error (a Graph-shaped body).
    def fail_next(status: 503, code: 2, title: "Service Unavailable")
      @script << [ :reply, status, { "error" => { "message" => "(##{code}) #{title} (simulated)", "type" => "OAuthException", "code" => code,
                                                   "error_data" => { "details" => "simulated by the demo" } } } ]
      self
    end

    # The next call "times out while reading the response": the message may or may not have arrived.
    def timeout_next
      @script << [ :error, Faraday::TimeoutError.new(Net::ReadTimeout.new) ]
      self
    end

    def calls = @requests.size

    def adapter = [ :test, stubs ]

    # The same idea for Catalog::Client: any call is answered here with an
    # empty success and recorded, so it can be asserted that none was made.
    def catalog_adapter = [ :test, catalog_stubs ]

    # True when `candidate` (a Faraday adapter spec as WhatsappClient.adapter or
    # Catalog::Client.adapter holds it) is one of this fake's own adapters.
    def owns?(candidate) = owns_whatsapp?(candidate) || owns_catalog?(candidate)

    def owns_whatsapp?(candidate) = candidate.is_a?(Array) && candidate.first == :test && candidate.last.equal?(stubs)

    def owns_catalog?(candidate) = candidate.is_a?(Array) && candidate.first == :test && candidate.last.equal?(catalog_stubs)

    private

    def catalog_stubs
      @catalog_stubs ||= Faraday::Adapter::Test::Stubs.new do |stubs|
        answer = proc do |env|
          @catalog_requests << { method: env.method, path: env.url.path }
          [ 200, { "Content-Type" => "application/json" }, JSON.generate("data" => [], "handles" => [], "validation_status" => []) ]
        end
        stubs.get(/.*/, &answer)
        stubs.post(/.*/, &answer)
      end
    end

    def stubs
      @stubs ||= Faraday::Adapter::Test::Stubs.new { |stubs| stubs.post(/.*/) { |env| respond(env) } }
    end

    def respond(env)
      @requests << { path: env.url.path, body_bytes: env.body.to_s.bytesize }
      kind, *args = @script.shift || [ :ok ]
      raise args.first if kind == :error

      status, body = kind == :reply ? args : [ 200, success_body ]
      [ status, { "Content-Type" => "application/json" }, JSON.generate(body) ]
    end

    def success_body
      @sent += 1
      { "messaging_product" => "whatsapp", "contacts" => [ { "input" => "demo", "wa_id" => "demo" } ],
        "messages" => [ { "id" => "#{@prefix}.#{@sent}" } ] }
    end
  end
end
