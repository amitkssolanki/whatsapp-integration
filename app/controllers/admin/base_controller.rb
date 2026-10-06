module Admin
  # Everything under /admin. HTTP Basic auth that fails closed: when either
  # credential is not configured nobody gets in, however the request is dressed.
  # The only opt-out is ADMIN_AUTH_DISABLED=1, honoured in development and test
  # only (Rails.env.local?); production ignores it.
  class BaseController < ApplicationController
    AUTH_DISABLED_OPERATOR = "dev-operator".freeze

    layout "admin"

    protect_from_forgery with: :exception

    before_action :authenticate_operator!
    helper_method :current_operator

    # The authenticated basic-auth username. It is the `by:` of every operator
    # action, so the audit trail says who pressed the button.
    attr_reader :current_operator

    private

    def authenticate_operator!
      if auth_disabled?
        @current_operator = AUTH_DISABLED_OPERATOR
        return
      end

      authenticate_or_request_with_http_basic("The Local Table operator") do |user, password|
        credentials_match?(user, password).tap { |ok| @current_operator = user if ok }
      end
    end

    def auth_disabled?
      Rails.env.local? && ENV["ADMIN_AUTH_DISABLED"] == "1"
    end

    def credentials_match?(user, password)
      expected_user = Rails.application.config.whatsapp.admin_user.to_s
      expected_password = Rails.application.config.whatsapp.admin_password.to_s
      return false if expected_user.blank? || expected_password.blank?

      # `&`, not `&&`: both comparisons always run.
      ActiveSupport::SecurityUtils.secure_compare(user.to_s, expected_user) &
        ActiveSupport::SecurityUtils.secure_compare(password.to_s, expected_password)
    end
  end
end
