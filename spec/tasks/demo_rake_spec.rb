require "rake"
require "rails_helper"

RSpec.describe "demo:simulate" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("demo:simulate") }

  let(:task) { Rake::Task["demo:simulate"] }

  before { task.reenable }

  it "refuses outside development without touching any data" do
    create_menu

    expect { task.invoke }.to raise_error(SystemExit).and output(/only in development/).to_stderr

    expect(Customer.count).to eq(0)
  end

  it "refuses in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))

    expect { task.invoke }.to raise_error(SystemExit).and output(/never runs in production/).to_stderr
  end

  it "in development, refuses a database that is not a demo one and prints how to run it" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))

    expect { task.invoke }.to raise_error(SystemExit)
      .and output(%r{_demo.*DATABASE_URL=postgres:///whatsapp_integration_demo bin/rails db:prepare db:seed demo:simulate}m).to_stderr
  end
end

RSpec.describe "demo:seed_integration and demo:purge_synthetic" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("demo:seed_integration") }

  let(:seed) { Rake::Task["demo:seed_integration"] }
  let(:purge) { Rake::Task["demo:purge_synthetic"] }

  around do |example|
    saved = ENV.delete("CONFIRM")
    example.run
  ensure
    saved ? ENV["CONFIRM"] = saved : ENV.delete("CONFIRM")
  end

  before do
    seed.reenable
    purge.reenable
  end

  describe "demo:seed_integration" do
    it "refuses without CONFIRM=yes, says what it would replace, and changes nothing" do
      Customer.create!(whatsapp_number: "15550102001", synthetic: true)

      expect { seed.invoke }.to raise_error(SystemExit).and output(/Refusing without CONFIRM=yes.*Nothing was changed.*customers: 1/m).to_stderr

      expect(Customer.count).to eq(1)
      expect(Product.count).to eq(0)
    end

    it "refuses any other CONFIRM value" do
      ENV["CONFIRM"] = "true"

      expect { seed.invoke }.to raise_error(SystemExit).and output(/Refusing without CONFIRM=yes/).to_stderr
      expect(Customer.count).to eq(0)
    end

    it "runs in ANY environment, production included, with zero HTTP, and prints the summary" do
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("production"))
      ENV["CONFIRM"] = "yes"

      expect { seed.invoke }.to output(/SYNTHETIC DATA.*customers: 11.*outbound messages: blocked 1, delivered 6/m).to_stdout

      expect(graph.calls).to eq(0)
      expect(Customer.synthetic.count).to eq(11)
    end

    it "is repeatable: a second run leaves the same counts" do
      ENV["CONFIRM"] = "yes"
      run = lambda do
        seed.reenable
        expect { seed.invoke }.to output(/customers: 11/).to_stdout
        [ Customer.count, Message.count, Order.count, WebhookDelivery.count, Product.count ]
      end

      expect(run.call).to eq(run.call)
    end

    it "aborts with the reason, leaving the previous data, when a guarantee is violated" do
      ENV["CONFIRM"] = "yes"
      allow_any_instance_of(Demo::FakeMeta).to receive(:catalog_requests).and_return([ { path: "/x" } ])

      expect { seed.invoke }.to raise_error(SystemExit).and output(/rolled everything back.*Catalog::Client was called/m).to_stderr

      expect(Customer.count).to eq(0)
    end
  end

  describe "demo:purge_synthetic" do
    it "refuses without CONFIRM=yes and changes nothing" do
      Customer.create!(whatsapp_number: "15550102001", synthetic: true)

      expect { purge.invoke }.to raise_error(SystemExit).and output(/Refusing without CONFIRM=yes.*customers: 1/m).to_stderr
      expect(Customer.count).to eq(1)
    end

    it "removes exactly the synthetic data and reports what it removed" do
      real = create_customer
      Customer.create!(whatsapp_number: "15550102001", synthetic: true).create_conversation!
      ENV["CONFIRM"] = "yes"

      expect { purge.invoke }.to output(/Removed synthetic data: customers 1, conversations 1/).to_stdout

      expect(Customer.all).to contain_exactly(real)
    end
  end
end
