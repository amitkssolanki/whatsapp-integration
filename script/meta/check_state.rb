# Read-only check of the Meta/WhatsApp setup this app depends on (Gate A).
#
#   bin/rails runner script/meta/check_state.rb
#
# Makes a fixed, small set of GET requests with the configured token and prints
# only non-personal fields. It cannot change anything: there is no code path for
# POST/DELETE, and every path is from the allowlist below. Run it once per check;
# it is not a monitor. Meta dashboard actions stay with the account owner.
require "faraday"
require "json"

config = Rails.application.config.whatsapp
abort "WHATSAPP_TOKEN is not set" if config.token.blank?

GRAPH = Faraday.new(url: "https://graph.facebook.com") do |f|
  f.options.open_timeout = 5
  f.options.timeout = 15
end

def get(path, params, token)
  response = GRAPH.get("/#{Rails.application.config.whatsapp.api_version}/#{path}", params) do |req|
    req.headers["Authorization"] = "Bearer #{token}"
  end
  body = JSON.parse(response.body) rescue {}
  [ response.status, body ]
end

def mask(number) = number.to_s.gsub(/\d(?=\d{4})/, "•")

def report(label, status, body)
  if status == 200
    puts "OK   #{label}"
    yield body if block_given?
  else
    error = body["error"] || {}
    puts "FAIL #{label}: HTTP #{status} code=#{error['code']} #{error['message'].to_s[0, 160]}"
  end
end

token = config.token
checks = []

if config.phone_number_id.present?
  status, body = get(config.phone_number_id, { fields: "platform_type,status,code_verification_status,quality_rating,name_status,messaging_limit_tier,display_phone_number,verified_name" }, token)
  report("phone number", status, body) do |b|
    puts "       platform_type=#{b['platform_type']} status=#{b['status']} verification=#{b['code_verification_status']}"
    puts "       quality=#{b['quality_rating']} name_status=#{b['name_status']} tier=#{b['messaging_limit_tier']}"
    puts "       number=#{mask(b['display_phone_number'])} verified_name=#{b['verified_name']}"
    checks << (b["platform_type"] == "CLOUD_API" && b["status"] == "CONNECTED")
  end
else
  puts "SKIP phone number: WHATSAPP_PHONE_NUMBER_ID not set"
end

if config.business_account_id.present?
  status, body = get("#{config.business_account_id}/subscribed_apps", {}, token)
  report("webhook subscription (subscribed_apps)", status, body) do |b|
    apps = Array(b["data"]).map { |a| a.dig("whatsapp_business_api_data", "name") || a["name"] || "app" }
    puts "       subscribed apps: #{apps.any? ? apps.join(', ') : 'NONE: inbound webhooks will not arrive'}"
    checks << apps.any?
  end

  status, body = get("#{config.business_account_id}/product_catalogs", {}, token)
  report("catalog linked to the WhatsApp Business Account", status, body) do |b|
    catalogs = Array(b["data"])
    puts "       linked catalogs: #{catalogs.size}#{catalogs.any? ? " (#{catalogs.map { |c| c['name'] }.join(', ')})" : ''}"
    puts "       matches CATALOG_ID: #{catalogs.any? { |c| c['id'].to_s == config.catalog_id.to_s }}" if config.catalog_id.present?
    checks << catalogs.any?
  end
else
  puts "SKIP WABA checks: WHATSAPP_BUSINESS_ACCOUNT_ID not set"
end

if config.catalog_id.present?
  status, body = get("#{config.catalog_id}/products", { fields: "retailer_id,price,availability,review_status", limit: 3, summary: "true" }, token)
  report("catalog read access (catalog_management)", status, body) do |b|
    puts "       products in catalog: #{b.dig('summary', 'total_count') || 'unknown'}"
    sample = Array(b["data"]).first
    puts "       sample price format: #{sample['price'].inspect} review_status=#{sample['review_status'].inspect}" if sample
    checks << true
  end
end

puts
ready = checks.any? && checks.all?
puts(ready ? "Gate A: all checks passed" : "Gate A: NOT ready (see FAIL/NONE above)")
