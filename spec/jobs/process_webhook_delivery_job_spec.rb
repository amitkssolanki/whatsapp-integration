require "rails_helper"

RSpec.describe ProcessWebhookDeliveryJob, type: :job do
  let(:body) { meta_fixture("text_greeting") }

  # Every class an infrastructure outage can surface as, each built from the
  # concrete class Rails (or the pg driver) actually raises.
  infrastructure_samples = {
    "ActiveRecord::ConnectionNotEstablished" => -> { ActiveRecord::ConnectionNotEstablished.new("pool gone") },
    "ActiveRecord::ConnectionTimeoutError" => -> { ActiveRecord::ConnectionTimeoutError.new("no free connection") },
    "ActiveRecord::DatabaseConnectionError" => -> { ActiveRecord::DatabaseConnectionError.new },
    "ActiveRecord::ConnectionFailed" => -> { ActiveRecord::ConnectionFailed.new("server closed the connection unexpectedly") },
    "ActiveRecord::QueryCanceled" => -> { ActiveRecord::QueryCanceled.new("canceling statement due to statement timeout") },
    "ActiveRecord::StatementTimeout" => -> { ActiveRecord::StatementTimeout.new("timeout") },
    "ActiveRecord::AdapterTimeout" => -> { ActiveRecord::AdapterTimeout.new("timeout") },
    "ActiveRecord::LockWaitTimeout" => -> { ActiveRecord::LockWaitTimeout.new("lock not available") },
    "ActiveRecord::Deadlocked" => -> { ActiveRecord::Deadlocked.new("deadlock detected") },
    "ActiveRecord::SerializationFailure" => -> { ActiveRecord::SerializationFailure.new("could not serialize access") },
    "ActiveRecord::TransactionRollbackError" => -> { ActiveRecord::TransactionRollbackError.new("rolled back") },
    "PG::ConnectionBad" => -> { PG::ConnectionBad.new("gone") },
    "PG::UnableToSend" => -> { PG::UnableToSend.new("gone") },
    "PG::AdminShutdown" => -> { PG::AdminShutdown.new("terminating connection due to administrator command") },
    "PG::CrashShutdown" => -> { PG::CrashShutdown.new("crash") },
    "PG::CannotConnectNow" => -> { PG::CannotConnectNow.new("the database system is starting up") }
  }

  def process_jobs = enqueued_jobs.select { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }

  describe "infrastructure errors" do
    infrastructure_samples.each do |name, build|
      it "retries #{name} and does not mark the delivery failed" do
        delivery = deliver(body)
        allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_raise(build.call)
        clear_enqueued_jobs

        described_class.perform_now(delivery.id)

        expect(delivery.reload).to have_attributes(status: "processing", attempts: 1, last_error_class: name)
        expect(process_jobs.size).to eq(1)
        expect(process_jobs.first["executions"]).to eq(1)
      end
    end

    it "retries a StatementInvalid whose cause is a server shutdown, which the adapter does not map to its own class" do
      delivery = deliver(body)
      wrapped = begin
        begin
          raise PG::AdminShutdown, "terminating connection"
        rescue PG::AdminShutdown
          raise ActiveRecord::StatementInvalid, "PG::AdminShutdown: ERROR"
        end
      rescue ActiveRecord::StatementInvalid => e
        e
      end
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_raise(wrapped)
      clear_enqueued_jobs

      described_class.perform_now(delivery.id)

      expect(delivery.reload).to be_processing
      expect(process_jobs.size).to eq(1)
    end

    it "does not treat ordinary data errors as infrastructure" do
      [ ActiveRecord::RecordNotUnique.new("dup"), ActiveRecord::StatementInvalid.new("bad sql"), ActiveRecord::RecordInvalid.new,
        ActiveRecord::NotNullViolation.new("null"), NoMethodError.new("boom") ].each do |error|
        expect(Webhooks::InfrastructureError === error).to be(false), "#{error.class} must not be retried"
      end
    end

    it "only lists classes that exist in the installed gems" do
      expect(Webhooks::InfrastructureError::CLASSES).to all(be_a(Class))
      expect(Webhooks::InfrastructureError::CLASSES.map(&:name)).to include("ActiveRecord::QueryAborted", "PG::AdminShutdown")
      expect(ActiveRecord::ConnectionFailed.ancestors).to include(ActiveRecord::QueryAborted) # covered through its parent
    end

    it "resumes the delivery on the retry, counts the attempt and ends processed with the error cleared" do
      delivery = deliver(body)
      calls = 0
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_wrap_original do |original|
        calls += 1
        raise ActiveRecord::ConnectionFailed, "restart" if calls == 1

        original.call
      end

      described_class.perform_now(delivery.id)
      perform_enqueued_jobs(only: described_class)

      expect(delivery.reload).to have_attributes(status: "processed", attempts: 2, last_error_class: nil)
      expect(Message.outbound.count).to eq(1)
    end

    it "fails the delivery (replayable) only when the attempts run out" do
      delivery = deliver(body)
      allow_any_instance_of(Webhooks::MessageHandler).to receive(:call).and_raise(ActiveRecord::ConnectionFailed, "restart")

      expect { 3.times { perform_enqueued_jobs(only: described_class) } }.to raise_error(ActiveRecord::ConnectionFailed)

      expect(delivery.reload).to be_failed
      expect(delivery).to be_replayable
    end
  end
end
