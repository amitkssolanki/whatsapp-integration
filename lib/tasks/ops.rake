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

  desc "Scenario 3: re-ingest a stored delivery's exact bytes and signature as a new, labeled (injected:repost) delivery: ID=<delivery id> CONFIRM=yes"
  task repost_delivery: :environment do
    id = Integer(ENV["ID"].to_s, exception: false) or abort "ID=<delivery id> is required, e.g. bin/rails ops:repost_delivery ID=42 CONFIRM=yes"
    abort "Refusing without CONFIRM=yes: this stores a second copy of delivery ##{id} (labeled injected:repost) and processes it. Nothing was changed." unless ENV["CONFIRM"] == "yes"

    begin
      copy = Ops::Repost.new(id).call
    rescue Ops::Repost::Refused => e
      abort e.message
    end
    puts "Re-posted delivery ##{id} as delivery ##{copy.id} (#{copy.status}), labeled #{copy.injected_faults.join(', ')}."
  end

  desc "End-of-period purge: BEFORE=2026-12-01 CONFIRM=yes [FORCE=yes] removes raw bodies, message text, names and phone numbers (docs/operating/PROTOCOL.md). Alias: ops:purge_payloads"
  task purge: :environment do
    before_text = ENV["BEFORE"].to_s
    abort "BEFORE=YYYY-MM-DD is required, e.g. bin/rails ops:purge BEFORE=2026-12-01 CONFIRM=yes" unless before_text.match?(/\A\d{4}-\d{2}-\d{2}\z/)

    before = begin
      Time.zone.parse(before_text)
    rescue ArgumentError
      nil
    end
    abort "BEFORE must be a real date, not #{before_text.inspect}" unless before

    force = ENV["FORCE"] == "yes"
    purge = begin
      Ops::Purge.new(before: before, force: force)
    rescue Ops::Purge::FutureDate => e
      abort e.message
    end

    describe_counts = lambda do |counts, would|
      [
        "  webhook_deliveries (raw body, outcome refs) #{would ? 'to purge' : 'purged'}: #{counts[:deliveries]}",
        "  messages (body, payload, wa id, error details) #{would ? 'to purge' : 'purged'}: #{counts[:messages]}",
        "  customers (name, phone, user id) #{would ? 'to anonymise' : 'anonymised'}: #{counts[:customers]}",
        "  orders (order note) #{would ? 'to clear' : 'cleared'}: #{counts[:orders]}",
        "  SKIPPED, still in use and kept intact (FORCE=yes purges them too):",
        "    webhook_deliveries: #{counts[:skipped_deliveries]} #{counts.dig(:held, :deliveries).inspect}",
        "    outbound messages:  #{counts[:skipped_messages]} #{counts.dig(:held, :messages).inspect}",
        "    customers with such a message: #{counts[:skipped_customers]}"
      ].join("\n")
    end

    unless ENV["CONFIRM"] == "yes"
      abort "Refusing to purge without CONFIRM=yes. Nothing was changed. Records before #{before_text} that would be purged:\n" \
            "#{describe_counts.call(purge.preview, true)}"
    end

    puts "Purged before #{before_text}#{' (FORCE)' if force}:"
    puts describe_counts.call(purge.call, false)
  end

  task purge_payloads: :purge
end
