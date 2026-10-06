namespace :ops do
  desc "Operations report from the database: FROM=2026-10-20 TO=2026-11-10 FORMAT=json|md (default: last 24h, json)"
  task report: :environment do
    format = ENV.fetch("FORMAT", "json").downcase
    abort "FORMAT must be json or md, not #{format.inspect}" unless %w[json md].include?(format)

    to = ENV["TO"].present? ? Time.zone.parse(ENV["TO"]) : Time.current
    from = ENV["FROM"].present? ? Time.zone.parse(ENV["FROM"]) : to - 24.hours
    abort "FROM and TO must be dates or times, e.g. FROM=2026-10-20 TO=2026-11-10" unless from && to

    begin
      report = Ops::Report.new(from: from, to: to)
    rescue ArgumentError => e
      abort e.message
    end

    puts(format == "md" ? report.to_markdown : JSON.pretty_generate(report.call))
  end
end
