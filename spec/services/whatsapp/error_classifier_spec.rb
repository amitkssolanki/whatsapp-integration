require "rails_helper"

RSpec.describe Whatsapp::ErrorClassifier do
  {
    131009 => "request_invalid",
    131030 => "recipient_not_allowed",
    133010 => "account_config"
  }.each do |code, category|
    it "maps the V1-observed code #{code} to #{category}" do
      expect(described_class.category_for(code: code)).to eq(category)
    end
  end

  it "leaves every other code unclassified until the taxonomy is confirmed against Meta's docs" do
    [ 190, 131026, 131047, 131048, 0, nil ].each do |code|
      expect(described_class.category_for(code: code)).to eq("unclassified")
    end
    expect(described_class.category_for(code: nil, http_status: 429)).to eq("unclassified")
  end
end
