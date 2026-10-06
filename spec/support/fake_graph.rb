# A scripted stand-in for graph.facebook.com, wired in through Faraday's
# built-in test adapter. WhatsappClient.adapter is pointed at it for every
# example, so no spec can reach the network: a request nobody scripted raises.
#
#   graph.reply(200, ok_send("wamid.FAKE1"))      # queue one response
#   graph.reply(400, graph_error(131030))         # next call gets this
#   graph.fail_with(Faraday::TimeoutError.new)    # next call raises
#   graph.requests                                # everything that was sent
class FakeGraph
  Request = Struct.new(:method, :path, :headers, :body, keyword_init: true) do
    def json = JSON.parse(body)
  end

  class Unscripted < StandardError; end

  attr_reader :requests

  def initialize
    @script = []
    @requests = []
  end

  def reply(status = 200, body = {}, headers = {})
    @script << [ :reply, status, body, headers ]
    self
  end

  def fail_with(error)
    @script << [ :error, error ]
    self
  end

  def calls = @requests.size

  def stubs
    @stubs ||= Faraday::Adapter::Test::Stubs.new do |stubs|
      stubs.post(/.*/) { |env| respond(env) }
    end
  end

  def adapter = [ :test, stubs ]

  private

  def respond(env)
    @requests << Request.new(method: env.method, path: env.url.path, headers: env.request_headers.to_h, body: env.body.to_s)
    step = @script.shift or raise Unscripted, "unscripted HTTP call to #{env.url.path}"
    kind, *args = step

    if kind == :error
      raise args.first
    else
      status, body, headers = args
      [ status, { "Content-Type" => "application/json" }.merge(headers), body.is_a?(String) ? body : JSON.generate(body) ]
    end
  end
end

module FakeGraphHelpers
  def graph = (@graph ||= FakeGraph.new)

  # Gives the app credentials so a send actually reaches the (fake) wire.
  def configure_whatsapp
    config = Rails.application.config.whatsapp
    config.token = "test-token"
    config.phone_number_id = "100000000000003"
  end

  def ok_send(wamid = "wamid.FAKE0001")
    { "messaging_product" => "whatsapp", "contacts" => [ { "input" => "x", "wa_id" => "x" } ], "messages" => [ { "id" => wamid } ] }
  end

  # An error body shaped like Meta's (see spec/fixtures/meta/v1/graph_error_*.json).
  def graph_error(code, message: "Something went wrong", details: nil)
    { "error" => { "message" => "(##{code}) #{message}", "type" => "OAuthException", "code" => code,
                   "error_data" => { "messaging_product" => "whatsapp", "details" => details || message }, "fbtrace_id" => "FAKETRACE" } }
  end
end

RSpec.configure do |config|
  config.include FakeGraphHelpers

  config.around do |example|
    saved = WhatsappClient.adapter
    WhatsappClient.adapter = graph.adapter
    example.run
  ensure
    WhatsappClient.adapter = saved
  end
end
