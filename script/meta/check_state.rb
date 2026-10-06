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

# Digits only, so "+1 555 010 1234" masks to •••••••1234 (masking the formatted
# string left most digits visible: each group shorter than 5 digits kept them).
def mask(number)
  d = number.to_s.gsub(/\D/, "")
  d.length > 4 ? ("•" * (d.length - 4)) + d[-4..] : d
end

def digits(number) = number.to_s.gsub(/\D/, "")

# WHATSAPP_DISPLAY_PHONE_NUMBER, when set: the number this project is meant to use.
EXPECTED_NUMBER = Rails.application.config.whatsapp.display_phone_number

def expected_number?(display) = EXPECTED_NUMBER.present? && digits(display) == EXPECTED_NUMBER

# Every check records a result; a failed request is a failed check. (The first
# version only recorded checks that succeeded, so a FAIL could still end in
# "all checks passed".)
CHECKS = []

def report(label, status, body)
  if status == 200
    puts "OK   #{label}"
    yield body if block_given?
  else
    error = body["error"] || {}
    puts "FAIL #{label}: HTTP #{status} code=#{error['code']} #{error['message'].to_s[0, 160]}"
    CHECKS << false
  end
end

token = config.token
checks = CHECKS
puts "Expected business number: #{EXPECTED_NUMBER.present? ? mask(EXPECTED_NUMBER) : 'not set (WHATSAPP_DISPLAY_PHONE_NUMBER)'}"

if config.phone_number_id.present?
  status, body = get(config.phone_number_id, { fields: "platform_type,status,code_verification_status,quality_rating,name_status,messaging_limit_tier,display_phone_number,verified_name" }, token)
  report("phone number", status, body) do |b|
    puts "       platform_type=#{b['platform_type']} status=#{b['status']} verification=#{b['code_verification_status']}"
    puts "       quality=#{b['quality_rating']} name_status=#{b['name_status']} tier=#{b['messaging_limit_tier']}"
    puts "       number=#{mask(b['display_phone_number'])} verified_name=#{b['verified_name']}"
    checks << (b["platform_type"] == "CLOUD_API" && b["status"] == "CONNECTED")
    if EXPECTED_NUMBER.present?
      matches = expected_number?(b["display_phone_number"])
      puts "       matches WHATSAPP_DISPLAY_PHONE_NUMBER (#{mask(EXPECTED_NUMBER)}): #{matches}"
      checks << matches
    end
  end
else
  puts "SKIP phone number: WHATSAPP_PHONE_NUMBER_ID not set"
  checks << false
end

if config.business_account_id.present?
  # Which numbers this WhatsApp Business Account holds now, so a phone number id
  # that no longer resolves can be compared with what actually exists.
  status, body = get("#{config.business_account_id}/phone_numbers", { fields: "id,display_phone_number,verified_name,platform_type,status,code_verification_status,quality_rating" }, token)
  report("phone numbers on the WhatsApp Business Account", status, body) do |b|
    numbers = Array(b["data"])
    puts "       #{numbers.size} number(s)#{numbers.empty? ? ': NONE' : ''}"
    numbers.each do |n|
      configured = n["id"].to_s == config.phone_number_id.to_s ? "  <- WHATSAPP_PHONE_NUMBER_ID" : ""
      configured += "  <- WHATSAPP_DISPLAY_PHONE_NUMBER" if expected_number?(n["display_phone_number"])
      puts "       id=#{n['id']} number=#{mask(n['display_phone_number'])} platform=#{n['platform_type']} status=#{n['status']} " \
           "verification=#{n['code_verification_status']} quality=#{n['quality_rating']}#{configured}"
    end
    checks << numbers.any? { |n| n["id"].to_s == config.phone_number_id.to_s && n["platform_type"] == "CLOUD_API" }
    if EXPECTED_NUMBER.present? && numbers.none? { |n| expected_number?(n["display_phone_number"]) }
      puts "       the expected number (#{mask(EXPECTED_NUMBER)}) is not on this account yet"
      checks << false
    end
  end

  status, body = get("#{config.business_account_id}/subscribed_apps", {}, token)
  report("webhook subscription (subscribed_apps)", status, body) do |b|
    apps = Array(b["data"]).map { |a| a.dig("whatsapp_business_api_data", "name") || a["name"] || "app" }
    puts "       subscribed apps: #{apps.any? ? apps.join(', ') : 'NONE: inbound webhooks will not arrive'}"
    checks << apps.any?
  end

  status, body = get("#{config.business_account_id}/product_catalogs", {}, token)
  report("catalog linked to the WhatsApp Business Account", status, body) do |b|
    catalogs = Array(b["data"])
    puts "       linked catalogs: #{catalogs.size}"
    catalogs.each { |c| puts "       id=#{c['id']} name=#{c['name']}" }
    if config.catalog_id.present?
      puts "       matches CATALOG_ID: #{catalogs.any? { |c| c['id'].to_s == config.catalog_id.to_s }}"
    else
      puts "       CATALOG_ID is not set: put the id above in .env to enable the catalog read check"
      checks << false
    end
    checks << catalogs.any?
  end
else
  puts "SKIP WABA checks: WHATSAPP_BUSINESS_ACCOUNT_ID not set"
  checks << false
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
