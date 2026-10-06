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

  desc "Purge raw webhook bodies and message payloads older than a date: BEFORE=2026-12-01 CONFIRM=yes (docs/operating/PROTOCOL.md)"
  task purge_payloads: :environment do
    before_text = ENV["BEFORE"].to_s
    abort "BEFORE=YYYY-MM-DD is required, e.g. bin/rails ops:purge_payloads BEFORE=2026-12-01 CONFIRM=yes" unless before_text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    before = begin
      Time.zone.parse(before_text)
    rescue ArgumentError
      nil
    end
    abort "BEFORE must be a real date, not #{before_text.inspect}" unless before
    abort "BEFORE must not be in the future" if before > Time.current

    purge = Ops::Purge.new(before: before)
    unless ENV["CONFIRM"] == "yes"
      counts = purge.preview
      abort "Refusing to purge without CONFIRM=yes. It would blank #{counts[:deliveries]} webhook delivery bodies and " \
            "#{counts[:messages]} message payloads received/created before #{before_text}. Nothing was changed."
    end

    counts = purge.call
    puts "Purged payloads before #{before_text}:"
    puts "  webhook_deliveries raw_body blanked: #{counts[:deliveries]}"
    puts "  messages raw_payload cleared:        #{counts[:messages]}"
    puts "  in-flight outbound messages skipped: #{counts[:skipped_in_flight]}"
  end
end
