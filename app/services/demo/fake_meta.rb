require "net/http"

module Demo
  # An in-process stand-in for graph.facebook.com for the demo simulator: a
  # Faraday test adapter, so a request to it is answered here and can never
  # leave the process, whatever token is configured. It answers 200 with a
  # synthetic message id unless told to fail the next call.
  class FakeMeta
    attr_reader :requests

    # `prefix` makes the synthetic message ids unique per simulator run.
    def initialize(prefix: "wamid.DEMO.out")
      @prefix = prefix
      @script = []
      @requests = []
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

    private

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
