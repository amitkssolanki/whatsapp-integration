# Builds sanitized test fixtures from the real V1 Meta webhook traffic.
#
#   ruby script/sanitize_v1_payloads.rb PATH/TO/archived/development.log spec/fixtures/meta/v1
#
# The archived log (kept outside the repo, see the V1 evidence manifest) holds real
# phone numbers, names and Meta IDs. This script never copies any of them: every
# identifier is replaced by a synthetic value through a deterministic mapping, so
# relationships survive (the same real message ID always maps to the same fake ID,
# which keeps Meta's real duplicate delivery a duplicate in the fixtures).
#
# Field names, nesting and value TYPES are preserved exactly (e.g. real order
# payloads send numeric quantity/item_price). Byte layout is not: the log holds
# parsed params, not raw bodies, so specs sign the re-serialized JSON themselves.
require "json"
require "digest"
require "base64"
require "fileutils"

log_path, out_dir = ARGV
abort "usage: #{$PROGRAM_NAME} LOG OUT_DIR" unless log_path && out_dir

class Sanitizer
  PHONE_KEYS = %w[from wa_id recipient_id display_phone_number input].freeze
  # Free text typed by real people can contain names; only these survive verbatim.
  SAFE_TEXT = [ "Hi", "Hello", "hi", "hello", "menu", "" ].freeze

  def initialize
    @maps = Hash.new { |h, k| h[k] = {} }
  end

  def call(node, key = nil)
    case node
    when Hash then node.to_h { |k, v| [ k, call(v, k) ] }
    when Array then node.map { |v| call(v, key) }
    when String then scrub_string(node, key)
    else node
    end
  end

  def mapping_report
    @maps.transform_values(&:size)
  end

  # Every real value that was replaced. Used to prove none of them reached the output.
  def originals
    @maps.values.flat_map(&:keys)
  end

  private

  def scrub_string(value, key)
    return synthetic(:wamid, value) { |n| fake_wamid(n) } if value.start_with?("wamid.")
    return synthetic(:user_id, value) { |n| format("US.%016d", 1_000_000_000_000_000 + n) } if key.to_s.end_with?("user_id")
    return synthetic(:phone, value) { |n| format("1555010%04d", n) } if PHONE_KEYS.include?(key)
    return synthetic(:name, value) { |n| "Test Customer #{n}" } if key == "name"
    return synthetic(:fbtrace, value) { |n| "FAKETRACE#{n}" } if key == "fbtrace_id"
    return SAFE_TEXT.include?(value) ? value : synthetic(:text, value) { |n| "test message #{n}" } if key == "body"
    if key == "id" || key == "phone_number_id" || key == "catalog_id"
      return value unless value.match?(/\A\d{8,}\z/)
      return synthetic(:graph_id, value) { |n| (100_000_000_000_000 + n).to_s }
    end
    value
  end

  def synthetic(kind, original)
    @maps[kind][original] ||= yield(@maps[kind].size + 1)
  end

  # Same overall shape as a real Cloud API message ID, built from fake parts only.
  def fake_wamid(n)
    number = format("1555010%04d", 1)
    tail = Base64.strict_encode64(Digest::SHA256.digest("fixture-#{n}"))[0, 24]
    "wamid.HBgL#{Base64.strict_encode64(number).delete('=')}FQIAERgS#{tail}AA=="
  end
end

def ruby_inspect_to_json(str)
  json = str.gsub('" => ', '": ').gsub(/(?<=[\s\[:{,])nil(?=[,}\]])/, "null")
  JSON.parse(json)
end

lines = File.readlines(log_path, encoding: "UTF-8")
webhooks = []
graph_errors = []
lines.each_with_index do |line, i|
  if line.include?('Started POST "/webhooks/whatsapp"') && !line.include?(" for ::1 ") && !line.include?(" for 127.0.0.1 ")
    params_line = lines[i + 1, 4].find { |l| l.include?("Parameters: {") }
    next unless params_line
    payload = ruby_inspect_to_json(params_line[/Parameters: (\{.*\})\s*\z/, 1])
    payload.delete("whatsapp") # ParamsWrapper's duplicate copy, not part of Meta's body
    webhooks << { line: i + 1, at: line[/at (\S+ \S+)/, 1], payload: payload }
  elsif (m = line.match(/send failed: (\d{3}) (\{.*\})\s*\z/))
    graph_errors << { status: m[1].to_i, body: JSON.parse(m[2]) }
  end
end

sanitizer = Sanitizer.new
webhooks.each { |w| w[:payload] = sanitizer.call(w[:payload]) }
graph_errors.each { |e| e[:body] = sanitizer.call(e[:body]) }

def value_of(payload) = payload.dig("entry", 0, "changes", 0, "value")

FileUtils.mkdir_p(out_dir)
FileUtils.rm_f(Dir[File.join(out_dir, "*.json")])
write = ->(name, data) { File.write(File.join(out_dir, name), JSON.pretty_generate(data) + "\n") }

orders = webhooks.select { |w| value_of(w[:payload])&.dig("messages", 0, "type") == "order" }
texts = webhooks.select { |w| value_of(w[:payload])&.dig("messages", 0, "type") == "text" }
statuses = webhooks.select { |w| value_of(w[:payload])&.key?("statuses") }

write.call("order.json", orders.first[:payload])
greeting = texts.find { |w| value_of(w[:payload]).dig("messages", 0, "text", "body") == "Hi" } || texts.first
write.call("text_greeting.json", greeting[:payload])
%w[sent delivered read].each do |s|
  hit = statuses.find { |w| value_of(w[:payload]).dig("statuses", 0, "status") == s }
  write.call("status_#{s}.json", hit[:payload]) if hit
end

# Meta's real duplicate delivery: identical status item in two separate POSTs.
dup = statuses.group_by { |w| value_of(w[:payload])["statuses"].to_json }.values.find { |g| g.size > 1 }
if dup
  write.call("status_duplicate_delivery_a.json", dup[0][:payload])
  write.call("status_duplicate_delivery_b.json", dup[1][:payload])
end

graph_errors.uniq { |e| e[:body].dig("error", "code") }.each do |e|
  write.call("graph_error_#{e[:body].dig('error', 'code')}.json", { "http_status" => e[:status], "body" => e[:body] })
end

# Fail closed: no replaced value, and nothing shaped like a real country-scoped user ID
# or a non-synthetic phone number, may appear anywhere in the written fixtures.
written = Dir[File.join(out_dir, "*.json")].map { |f| File.read(f) }.join("\n")
leaks = sanitizer.originals.select { |o| o.size >= 4 && written.include?(o) }
leaks += written.scan(/"[A-Z]{2}\.\d{10,}"/).reject { |v| v.start_with?('"US.1000') }
leaks += written.scan(/"\d{11,15}"/).reject { |v| v.start_with?('"1555010') || v.start_with?('"1000000') }
abort "PII LEAK in fixtures, nothing is safe to commit: #{leaks.uniq.size} values" if leaks.any?

puts "real webhook POSTs: #{webhooks.size} (orders #{orders.size}, texts #{texts.size}, statuses #{statuses.size})"
puts "duplicate status delivery found: #{dup ? "yes (log lines #{dup.map { |w| w[:line] }.join(', ')})" : 'no'}"
puts "graph error codes: #{graph_errors.map { |e| e[:body].dig('error', 'code') }.uniq.join(', ')}"
puts "synthetic mappings: #{sanitizer.mapping_report}"
puts "leak check: passed"
