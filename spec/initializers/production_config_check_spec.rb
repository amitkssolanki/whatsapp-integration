require "rails_helper"

RSpec.describe ProductionConfigCheck do
  let(:valid_env) do
    ProductionConfigCheck::REQUIRED_ENV.index_with { |name| "value-for-#{name.downcase}" }
  end

  it "passes when every required variable is present" do
    expect { described_class.call(valid_env) }.not_to raise_error
  end

  it "lists every missing variable in one error" do
    env = valid_env.except("WHATSAPP_TOKEN", "APP_HOST", "ADMIN_PASSWORD")

    expect { described_class.call(env) }.to raise_error(ProductionConfigCheck::Error) { |error|
      expect(error.message).to include("WHATSAPP_TOKEN", "APP_HOST", "ADMIN_PASSWORD")
      expect(error.message).not_to include("WHATSAPP_APP_SECRET")
    }
  end

  it "reports every required variable when the environment is empty" do
    expect { described_class.call({}) }.to raise_error(ProductionConfigCheck::Error) { |error|
      ProductionConfigCheck::REQUIRED_ENV.each { |name| expect(error.message).to include(name) }
    }
  end

  it "treats blank values as missing" do
    env = valid_env.merge("WHATSAPP_VERIFY_TOKEN" => "  ", "ADMIN_USER" => "")

    expect { described_class.call(env) }
      .to raise_error(ProductionConfigCheck::Error, /WHATSAPP_VERIFY_TOKEN, ADMIN_USER/)
  end

  it "refuses WHATSAPP_ALLOW_UNSIGNED, whatever its value" do
    %w[1 true 0].each do |value|
      expect { described_class.call(valid_env.merge("WHATSAPP_ALLOW_UNSIGNED" => value)) }
        .to raise_error(ProductionConfigCheck::Error, /WHATSAPP_ALLOW_UNSIGNED/)
    end
  end

  it "never echoes secret values in the message" do
    env = valid_env.except("APP_HOST").merge("WHATSAPP_ALLOW_UNSIGNED" => "1")

    expect { described_class.call(env) }.to raise_error(ProductionConfigCheck::Error) { |error|
      expect(error.message).not_to include("value-for-whatsapp_token")
    }
  end

  describe ".skip?" do
    it "skips during asset precompilation" do
      expect(described_class.skip?("SECRET_KEY_BASE_DUMMY" => "1")).to be(true)
    end

    it "does not skip otherwise" do
      expect(described_class.skip?({})).to be(false)
    end
  end
end
