require "rails_helper"

RSpec.describe "Admin authentication", type: :request do
  let(:path) { "/admin/orders" }

  context "with credentials configured" do
    before { configure_admin_credentials }

    it "answers 401 with a challenge when no credentials are sent" do
      get path

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to start_with("Basic")
    end

    it "answers 401 for a wrong password, a wrong user, and both wrong" do
      [ { password: "nope" }, { user: "intruder" }, { user: "intruder", password: "nope" } ].each do |wrong|
        get path, headers: admin_headers(**wrong)
        expect(response).to have_http_status(:unauthorized), wrong.inspect
      end
    end

    it "answers 200 for the right credentials" do
      get path, headers: admin_headers

      expect(response).to have_http_status(:ok)
    end

    it "does not let the dev opt-out leak into other values" do
      ENV["ADMIN_AUTH_DISABLED"] = "true"
      get path
      expect(response).to have_http_status(:unauthorized)
    ensure
      ENV.delete("ADMIN_AUTH_DISABLED")
    end
  end

  context "with credentials not configured (fail closed)" do
    it "denies a request without a header" do
      get path

      expect(response).to have_http_status(:unauthorized)
    end

    it "denies any header, including empty credentials and the would-be defaults" do
      [ [ "", "" ], [ "admin", "admin" ], [ "operator", "" ] ].each do |user, password|
        get path, headers: admin_headers(user: user, password: password)
        expect(response).to have_http_status(:unauthorized), [ user, password ].inspect
      end
    end

    it "denies when only one credential is configured" do
      Rails.application.config.whatsapp.admin_user = "operator"
      get path, headers: admin_headers(password: "")
      expect(response).to have_http_status(:unauthorized)

      Rails.application.config.whatsapp.admin_user = nil
      Rails.application.config.whatsapp.admin_password = "secret"
      get path, headers: admin_headers(user: "", password: "secret")
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "ADMIN_AUTH_DISABLED=1 (development and test only)" do
    around do |example|
      ENV["ADMIN_AUTH_DISABLED"] = "1"
      example.run
    ensure
      ENV.delete("ADMIN_AUTH_DISABLED")
    end

    it "lets requests through without credentials" do
      get path

      expect(response).to have_http_status(:ok)
    end

    it "is ignored outside local environments" do
      allow(Rails.env).to receive(:local?).and_return(false)

      get path

      expect(response).to have_http_status(:unauthorized)
    end
  end

  it "is inherited by every admin controller" do
    controllers = Dir[Rails.root.join("app/controllers/admin/*_controller.rb")].map { |f| File.basename(f, ".rb").camelize.prepend("Admin::").constantize }

    expect(controllers).to all(satisfy { |c| c <= Admin::BaseController })
  end
end
