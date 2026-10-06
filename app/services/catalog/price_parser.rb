module Catalog
  # Parses the `price` Meta returns when reading products back.
  #
  # The format of that field is undocumented (the push side takes "15.50 USD";
  # reads have been reported as "$15.50", "15.50 USD" and minor-unit integers
  # alongside a separate `currency` field), so this accepts every plausible
  # shape and refuses to guess when a value is ambiguous. Everything that knows
  # about those shapes lives here so the first live read-back only needs this
  # file and its spec changed.
  #
  #   PriceParser.parse("15.50 USD")      => #<data cents=1550, currency="USD">
  #   PriceParser.parse("$15.50")         => cents=1550, currency="USD"
  #   PriceParser.parse("USD15.50")       => cents=1550, currency="USD"
  #   PriceParser.parse("1550", currency: "USD") => cents=1550 (bare digits are minor units)
  #   PriceParser.parse(1550)             => cents=1550, currency=nil
  #   PriceParser.parse("15.505 USD")     => nil (more than two decimals)
  #
  # Rules: a bare integer or digit string is minor units (cents); a number with
  # a currency symbol/code but no decimals ("15 USD") is major units; decimals
  # are major units. Floats are read through their decimal text, never
  # multiplied as binary floats. Returns nil when unparseable, negative, or
  # more precise than a cent. Every currency is treated as two-decimal, like the
  # rest of the app.
  module PriceParser
    Result = Data.define(:cents, :currency)

    SYMBOLS = { "$" => "USD", "€" => "EUR", "£" => "GBP" }.freeze
    SHAPE = /\A(?<pre>[A-Za-z]{3}|[$€£])?\s*(?<number>-?[\d.,]+)\s*(?<post>[A-Za-z]{3})?\z/

    module_function

    def parse(value, currency: nil)
      case value
      when Integer then build(value, currency)
      when Float, BigDecimal then from_major(BigDecimal(value.to_s), currency)
      when String then parse_string(value.strip, currency)
      end
    end

    def parse_string(text, currency_field)
      match = SHAPE.match(text)
      return unless match

      marker_pre = marker(match[:pre])
      marker_post = marker(match[:post])
      return if marker_pre && marker_post && marker_pre != marker_post

      embedded = marker_pre || marker_post
      currency = embedded || normalize_currency(currency_field)

      number = normalize_number(match[:number])
      return unless number

      if number.match?(/\A\d+\z/) && embedded.nil?
        build(number.to_i, currency)             # bare digits: minor units
      else
        from_major(BigDecimal(number), currency) # has a decimal point or a currency marker
      end
    end

    def from_major(amount, currency)
      return unless amount.finite?

      cents = amount * 100
      return unless cents == cents.truncate

      build(cents.to_i, currency)
    end

    def build(cents, currency)
      return if cents.negative?

      Result.new(cents: cents, currency: normalize_currency(currency))
    end

    def marker(token)
      return if token.nil?

      SYMBOLS[token] || token.upcase
    end

    def normalize_currency(currency)
      code = currency.to_s.strip.upcase
      code.match?(/\A[A-Z]{3}\z/) ? code : nil
    end

    # Returns "1550.5"-style plain digits with an optional ".dd" fraction, or
    # nil if the separators are ambiguous or malformed.
    def normalize_number(raw)
      return if raw.start_with?("-")

      dots = raw.count(".")
      commas = raw.count(",")

      if dots.zero? && commas.zero?
        raw
      elsif commas.zero?
        raw if dots == 1 && raw.match?(/\A\d+\.\d{1,2}\z/)
      elsif dots.zero?
        if raw.match?(/\A\d{1,3}(,\d{3})+\z/) then raw.delete(",")   # 1,550 thousands
        elsif raw.match?(/\A\d+,\d{1,2}\z/) then raw.tr(",", ".")    # 15,50 decimal comma
        end
      else
        decimal = raw.rindex(".") > raw.rindex(",") ? "." : ","
        thousands = decimal == "." ? "," : "."
        integer, fraction = raw.split(decimal, 2)
        return unless fraction.match?(/\A\d{1,2}\z/) && integer.match?(/\A\d{1,3}(#{Regexp.escape(thousands)}\d{3})+\z/)

        "#{integer.delete(thousands)}.#{fraction}"
      end
    end
  end
end
