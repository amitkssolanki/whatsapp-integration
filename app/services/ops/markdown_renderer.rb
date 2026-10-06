module Ops
  # Turns an Ops::Report result into a compact Markdown summary: a header and
  # one two-column table per section. Nested counts are flattened to dotted
  # rows ("by_status.failed"); duration summaries become one row each. The
  # `real` sections come first (what the platform did), then `all` (every row,
  # injected and simulated ones included), then what was injected.
  class MarkdownRenderer
    TITLES = {
      deliveries: "Webhook deliveries", orders: "Orders", outbound: "Outbound messages",
      latency: "Latency", status_anomalies: "Status anomalies", window: "24-hour window",
      catalog: "Catalog", inbound: "Inbound messages"
    }.freeze
    UNITS = { latency: "s", decision_minutes: "min" }.freeze
    STATS_KEYS = %i[n median min max].freeze

    def initialize(data)
      @data = data
    end

    def render
      period = @data.fetch(:period)
      lines = [ "# Operations report", "", "Period: #{period[:from]} to #{period[:to]} (end exclusive)  ",
                "Generated: #{period[:generated_at]}, commit #{period[:git_sha]}", "",
                "Quote the **Real** sections for platform behavior: rows with an injected fault or a re-posted body, and " \
                "synthetic or simulated demo data (customers, their messages and orders, flagged deliveries), are left out of them. **All** counts every row. Latency is from real rows only.", "" ]
      section_lines(lines, "Real", @data.fetch(:real))
      section_lines(lines, "All (injected and simulated rows included)", @data.fetch(:all).except(:latency))
      table(lines, "Injected and re-posted rows", @data.fetch(:injected), nil)
      lines.join("\n")
    end

    private

    def section_lines(lines, group, sections)
      sections.each do |section, values|
        table(lines, "#{group}: #{TITLES.fetch(section, section.to_s.tr('_', ' ').capitalize)}", values, UNITS[section])
      end
    end

    def table(lines, title, values, unit)
      lines << "## #{title}" << "" << "| Metric | Value |" << "| --- | --- |"
      rows(values, [], unit).each { |name, value| lines << "| #{name} | #{value} |" }
      lines << ""
    end

    def rows(value, path, unit)
      unit = UNITS.fetch(path.last, unit) if path.last
      return [ [ path.join("."), stats(value, unit) ] ] if stats?(value)
      return [ [ path.join("."), "none" ] ] if value.is_a?(Hash) && value.empty? && path.any?
      return value.flat_map { |key, inner| rows(inner, path + [ key ], unit) } if value.is_a?(Hash)

      [ [ path.join("."), value.nil? ? "-" : value ] ]
    end

    def stats?(value)
      value.is_a?(Hash) && value.keys == STATS_KEYS
    end

    def stats(value, unit)
      show = ->(number) { number.nil? ? "-" : "#{number}#{unit}" }
      "n=#{value[:n]}, median #{show.call(value[:median])}, min #{show.call(value[:min])}, max #{show.call(value[:max])}"
    end
  end
end
