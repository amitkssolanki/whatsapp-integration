require "rails_helper"

RSpec.describe Catalog::PriceParser do
  def parsed(value, **opts)
    result = described_class.parse(value, **opts)
    result && [ result.cents, result.currency ]
  end

  describe "with an embedded currency" do
    {
      "15.50 USD" => [ 1550, "USD" ],
      "15.50 usd" => [ 1550, "USD" ],
      "  15.50 USD  " => [ 1550, "USD" ],
      "USD 15.50" => [ 1550, "USD" ],
      "USD15.50" => [ 1550, "USD" ],
      "$15.50" => [ 1550, "USD" ],
      "$ 15.50" => [ 1550, "USD" ],
      "€4.50" => [ 450, "EUR" ],
      "£4.50" => [ 450, "GBP" ],
      "4.5 EUR" => [ 450, "EUR" ],
      "$15" => [ 1500, "USD" ],
      "15 USD" => [ 1500, "USD" ],
      "0.05 USD" => [ 5, "USD" ],
      "$0.99" => [ 99, "USD" ],
      "$1,550.00" => [ 155_000, "USD" ],
      "1,550.00 USD" => [ 155_000, "USD" ],
      "15,50 EUR" => [ 1550, "EUR" ],
      "1.550,00 EUR" => [ 155_000, "EUR" ],
      "$1,550" => [ 155_000, "USD" ],
      "$12,345,678.90" => [ 1_234_567_890, "USD" ],
      "$1,55" => [ 155, "USD" ],
      "12.345,6" => [ 1_234_560, nil ],
      "$15.50 USD" => [ 1550, "USD" ]
    }.each do |text, expected|
      it "reads #{text.inspect} as #{expected.inspect}" do
        expect(parsed(text)).to eq(expected)
      end
    end

    it "lets the embedded currency win over the currency field" do
      expect(parsed("15.50 EUR", currency: "USD")).to eq([ 1550, "EUR" ])
    end
  end

  describe "bare numbers" do
    it "treats an integer as minor units" do
      expect(parsed(1550)).to eq([ 1550, nil ])
      expect(parsed(1550, currency: "USD")).to eq([ 1550, "USD" ])
      expect(parsed(0)).to eq([ 0, nil ])
    end

    it "treats a digit string as minor units and takes the currency from the field" do
      expect(parsed("1550", currency: "USD")).to eq([ 1550, "USD" ])
      expect(parsed("1550")).to eq([ 1550, nil ])
    end

    it "treats a decimal string as major units" do
      expect(parsed("15.50", currency: "usd")).to eq([ 1550, "USD" ])
      expect(parsed("15.5")).to eq([ 1550, nil ])
    end

    it "reads floats and BigDecimals through their decimal text, never binary arithmetic" do
      expect(parsed(15.5)).to eq([ 1550, nil ])
      expect(parsed(19.99)).to eq([ 1999, nil ])
      expect(parsed(0.29)).to eq([ 29, nil ])
      expect(parsed(BigDecimal("4.50"))).to eq([ 450, nil ])
    end

    it "ignores a malformed currency field" do
      expect(parsed(1550, currency: "dollars")).to eq([ 1550, nil ])
    end
  end

  describe "unparseable input" do
    [
      nil, "", "   ", "free", "abc", "N/A", "USD", "$", ".", "15.", ".50", "1.2.3", "1,5,0",
      "15.505 USD", "1.550", "-5.00 USD", "-1", "$-5", "15.50 USD EUR", "USD 15.50 EUR",
      "15..50", "1,2345.00", "1e3", [], {}, :price, Float::NAN, Float::INFINITY, -1, -0.5
    ].each do |value|
      it "returns nil for #{value.inspect}" do
        expect(described_class.parse(value)).to be_nil
      end
    end
  end
end
