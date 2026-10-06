require "rails_helper"

# Review 2 #10a. Solid Queue stores the message of any exception that escapes a
# job in solid_queue_failed_executions (solid_queue 1.7.0,
# app/models/solid_queue/failed_execution.rb), so it must not carry a Meta
# message id or a phone number.
RSpec.describe ApplicationJob, type: :job do
  let(:wamid) { "wamid.HBgLMTU1NTAwMDEyMzQVAgASGBQzQTAxQUJDREVGMTIz" }
  let(:detail) { %(PG::UniqueViolation: ERROR: duplicate key value violates unique constraint "index_messages_on_wa_message_id" DETAIL: Key (wa_message_id)=(#{wamid}) already exists. phone 15550001234) }

  def with_job_class(&body)
    Class.new(described_class) do
      def self.name = "ScrubSpecJob"
      define_method(:perform, &body)
    end
  end

  it "re-raises an unexpected error with the message scrubbed, keeping its class and backtrace" do
    text = detail
    job = with_job_class { raise ActiveRecord::RecordNotUnique, text }

    error = begin
      job.perform_now
    rescue StandardError => e
      e
    end

    expect(error).to be_a(ActiveRecord::RecordNotUnique)
    expect(error.message).not_to include(wamid)
    expect(error.message).not_to include("15550001234")
    expect(error.message).to include("[wamid]", "[#]", "duplicate key value")
    expect(error.backtrace.first).to include("application_job_spec.rb")
  end

  it "leaves a message with nothing to scrub as the very same exception" do
    boom = RuntimeError.new("nothing sensitive here")
    job = with_job_class { raise boom }

    expect { job.perform_now }.to raise_error { |error| expect(error).to equal(boom) }
  end

  it "still lets retry_on recognise an infrastructure error whose message was scrubbed" do
    job = Class.new(described_class) do
      retry_on(*Webhooks::DeliveryProcessor::INFRASTRUCTURE_ERRORS, attempts: 3, wait: 0)
      def perform = raise(ActiveRecord::ConnectionNotEstablished, "pool gone for 15550001234")
    end
    stub_const("ScrubRetrySpecJob", job)

    expect { job.perform_now }.to change { enqueued_jobs.size }.by(1) # retried, not propagated
  end

  it "scrubs what the real jobs propagate (SendMessageJob here), not only a test class" do
    configure_whatsapp
    customer = create_customer
    open_window(customer.conversation)
    message = create_outbound(customer: customer)
    allow_any_instance_of(WhatsappClient).to receive(:send_message).and_raise(ArgumentError, "bad row for #{wamid}")

    expect { SendMessageJob.perform_now(message.id) }.to raise_error(ArgumentError) { |error|
      expect(error.message).to eq("bad row for [wamid]")
    }
  end
end
