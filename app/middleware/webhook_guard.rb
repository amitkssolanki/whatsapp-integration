# Cheap checks on POST /webhooks/whatsapp that run before Rails reads or
# parses the body (docs/v2/DESIGN.md §5). The controller repeats the signature
# check as defense in depth; this exists so an unauthenticated client cannot
# make the app buffer a huge body or do HMAC work over it.
#
#   413  Content-Length above MAX_BODY_BYTES, or a body without a length
#        (chunked) that grows past it while being read
#   401  no X-Hub-Signature-256 header (unless unsigned requests are allowed,
#        which only ever happens in development and test)
#
# Meta documents 3 MB as the maximum webhook payload. config/deploy.yml applies
# the same limit in kamal-proxy, so normally this is the second line.
class WebhookGuard
  MAX_BODY_BYTES = 3 * 1024 * 1024
  # Journey normalises the path before routing (doubled and trailing slashes
  # vanish), so the guard must too, or `/webhooks/whatsapp.json/` would skip
  # it. The route itself takes no format (config/routes.rb), but the guard
  # still ignores any ".ext" suffix, in depth.
  PATH = %r{\A/webhooks/whatsapp(?:\.[^/]*)?\z}
  SIGNATURE_ENV_KEY = "HTTP_X_HUB_SIGNATURE_256".freeze
  READ_CHUNK_BYTES = 64 * 1024

  def initialize(app, max_body_bytes: MAX_BODY_BYTES)
    @app = app
    @max_body_bytes = max_body_bytes
  end

  def call(env)
    return @app.call(env) unless guarded?(env)

    length = declared_length(env)
    return reject(400, "bad_content_length") if length == :invalid
    return reject(413, "payload_too_large") if length && length > @max_body_bytes
    return reject(401, "missing_signature") if unsigned?(env)
    return reject(413, "payload_too_large") if length.nil? && !buffer_within_limit!(env)

    @app.call(env)
  end

  private

  def guarded?(env)
    env["REQUEST_METHOD"] == "POST" && PATH.match?(normalized_path(env))
  end

  def normalized_path(env)
    path = env["PATH_INFO"].to_s.squeeze("/")
    path.length > 1 ? path.chomp("/") : path
  end

  def unsigned?(env)
    env[SIGNATURE_ENV_KEY].to_s.strip.empty? && !Whatsapp::Signature.unsigned_allowed?
  end

  # Integer, nil when there is no Content-Length (chunked), :invalid otherwise.
  def declared_length(env)
    header = env["CONTENT_LENGTH"]
    return nil if header.nil? || header.to_s.strip.empty?

    length = Integer(header.to_s, 10, exception: false)
    length && length >= 0 ? length : :invalid
  end

  # Reads a body of unknown length through a cap. Returns false as soon as it
  # exceeds the limit; otherwise leaves a rewound, size-known input in the env.
  def buffer_within_limit!(env)
    input = env["rack.input"]
    return true unless input

    buffer = StringIO.new("".b)
    total = 0
    while (chunk = input.read(READ_CHUNK_BYTES))
      total += chunk.bytesize
      return false if total > @max_body_bytes

      buffer.write(chunk)
    end
    buffer.rewind
    env["rack.input"] = buffer
    env["CONTENT_LENGTH"] = total.to_s
    true
  end

  def reject(status, reason)
    AppLog.event("webhook.rejected", reason: reason, stage: "guard")
    body = Rack::Utils::HTTP_STATUS_CODES.fetch(status)
    [ status, { "content-type" => "text/plain", "content-length" => body.bytesize.to_s, "connection" => "close" }, [ body ] ]
  end
end
