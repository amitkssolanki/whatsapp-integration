namespace :demo do
  desc "Populate a SEPARATE demo database with clearly simulated traffic for screenshots (development only; see Demo::Simulator)"
  task simulate: :environment do
    if (reason = Demo::Simulator.refusal)
      abort reason
    end

    begin
      result = Demo::Simulator.new(seed: Integer(ENV.fetch("SEED", "1"))).call
    rescue Demo::Refused => e
      abort e.message
    end

    puts Demo::Simulator.summary(result)
    abort "Some simulated scenarios did not behave as designed." unless result.passed?
  end

  desc "Fill the operator UI with clearly synthetic, in-process traffic: CONFIRM=yes. Safe in ANY environment, production included (docs/operating/PROTOCOL.md)"
  task seed_integration: :environment do
    unless ENV["CONFIRM"] == "yes"
      abort "Refusing without CONFIRM=yes. Nothing was changed.\n" \
            "This replaces ALL synthetic data (synthetic-flagged customers, their conversations, messages and orders, synthetic deliveries and DEMO-* products) " \
            "with a fresh, fixed set; it never touches anything else and never contacts Meta.\n" \
            "Synthetic rows that would be removed first: #{Demo::SyntheticPurge.new.preview.inspect}"
    end

    begin
      result = Demo::IntegrationSeed.new.call
    rescue Demo::IntegrationSeed::Violation, Demo::Sandbox::Violation, Demo::SyntheticPurge::Refused => e
      abort e.message
    end

    puts Demo::IntegrationSeed.summary(result)
  end

  desc "Remove exactly the synthetic data (what demo:seed_integration created): CONFIRM=yes. Non-synthetic rows are never touched"
  task purge_synthetic: :environment do
    purge = Demo::SyntheticPurge.new
    unless ENV["CONFIRM"] == "yes"
      abort "Refusing without CONFIRM=yes. Nothing was changed. Synthetic rows that would be removed: #{purge.preview.inspect}"
    end

    begin
      counts = purge.call
    rescue Demo::SyntheticPurge::Refused => e
      abort e.message
    end

    puts "Removed synthetic data: #{counts.map { |table, count| "#{table} #{count}" }.join(', ')}"
  end
end
