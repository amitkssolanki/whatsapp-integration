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
end
