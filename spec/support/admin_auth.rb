# Request specs for the operator UI. `include_context "admin operator"` configures
# the Basic credentials and sends them with every get/post, so examples read
# like a signed-in session. Auth specs do not include it and pass headers by hand.
module AdminAuth
  ADMIN_USER = "operator".freeze
  ADMIN_PASSWORD = "correct-horse-battery".freeze

  def admin_headers(user: ADMIN_USER, password: ADMIN_PASSWORD)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user, password) }
  end

  def configure_admin_credentials(user: ADMIN_USER, password: ADMIN_PASSWORD)
    Rails.application.config.whatsapp.admin_user = user
    Rails.application.config.whatsapp.admin_password = password
  end
end

RSpec.shared_context "admin operator" do
  include AdminAuth

  before { configure_admin_credentials }

  %i[get post].each do |verb|
    define_method(verb) do |path, **options|
      super(path, **options, headers: admin_headers.merge(options.fetch(:headers, {})))
    end
  end

  def follow_redirect!(headers: {}, **options)
    super(headers: admin_headers.merge(headers), **options)
  end
end

RSpec.configure do |config|
  config.include AdminAuth, type: :request

  # A developer's shell may have the dev opt-out set; auth specs must not see it.
  config.around(type: :request) do |example|
    saved = ENV.delete("ADMIN_AUTH_DISABLED")
    example.run
  ensure
    ENV["ADMIN_AUTH_DISABLED"] = saved if saved
  end
end
