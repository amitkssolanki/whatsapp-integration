# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# WhatsApp payloads are personal data (phone numbers, names, message text) and
# Meta message ids embed phone numbers. Rails feeds this list to the request
# log's "Parameters:" line and to ActiveRecord's inspect and SQL bind logging,
# so these never reach the log.
Rails.application.config.filter_parameters += [
  :whatsapp_number, :display_name, :wa_, :raw_body, :raw_payload, :body, :signature, :entry
]
