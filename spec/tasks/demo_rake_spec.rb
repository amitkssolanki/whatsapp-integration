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
