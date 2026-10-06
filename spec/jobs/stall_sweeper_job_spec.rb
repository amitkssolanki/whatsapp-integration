require "rails_helper"

RSpec.describe StallSweeperJob, type: :job do
  describe "deliveries" do
    it "fails deliveries that have been processing for more than 10 minutes" do
      stalled = create_delivery(status: :processing, last_attempted_at: 11.minutes.ago)
      never_attempted = create_delivery(status: :processing, received_at: 12.minutes.ago)

      described_class.perform_now

      expect(stalled.reload).to have_attributes(status: "failed", last_error_class: "Stalled", last_error_message: "stalled")
      expect(stalled.processed_at).to be_present
      expect(never_attempted.reload).to be_failed
      expect(stalled).to be_replayable
    end

    it "leaves recent processing deliveries and every other status alone" do
      recent = create_delivery(status: :processing, last_attempted_at: 2.minutes.ago)
      others = (WebhookDelivery.statuses.keys - [ "processing" ]).map { |s| create_delivery(status: s, received_at: 1.day.ago, last_attempted_at: 1.day.ago) }

      described_class.perform_now

      expect(recent.reload).to be_processing
      expect(others.map { |d| d.reload.status }).to eq(WebhookDelivery.statuses.keys - [ "processing" ])
    end
  end

  describe "outbound messages" do
    it "marks sends stuck in `sending` for more than 5 minutes as unknown, never failed or pending" do
      stuck = create_outbound(status: :sending)
      stuck.update_columns(updated_at: 6.minutes.ago)

      described_class.perform_now

      expect(stuck.reload.status).to eq("unknown")
      expect(stuck.unknown_at).to be_within(5.seconds).of(Time.current)
    end

    it "leaves recent sends and every other outbound status alone" do
      recent = create_outbound(status: :sending)
      others = (Message.statuses.keys - [ "sending" ]).map do |status|
        create_outbound(status: status).tap { |m| m.update_columns(updated_at: 1.day.ago) }
      end

      described_class.perform_now

      expect(recent.reload).to be_sending
      expect(others.map { |m| m.reload.status }).to eq(Message.statuses.keys - [ "sending" ])
    end
  end

  describe "self-healing: deliveries stuck in `received`" do
    def queue_row(job_class, id, **attrs)
      SolidQueue::Job.create!({ queue_name: "default", class_name: job_class, active_job_id: SecureRandom.uuid,
                                arguments: { "job_class" => job_class, "arguments" => [ id ] } }.merge(attrs))
    end

    def process_jobs = enqueued_jobs.select { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }

    it "re-enqueues a delivery received more than 5 minutes ago that has no queued job" do
      lost = create_delivery(status: :received, received_at: 6.minutes.ago)

      described_class.perform_now

      expect(process_jobs.map { |job| job["arguments"].first }).to eq([ lost.id ])
      expect(lost.reload).to be_received
    end

    it "leaves a recent received delivery alone" do
      create_delivery(status: :received, received_at: 4.minutes.ago)

      described_class.perform_now

      expect(process_jobs).to be_empty
    end

    it "does not pile on when a job for it is still queued, but does when that job is finished or failed" do
      queued = create_delivery(status: :received, received_at: 1.hour.ago)
      finished = create_delivery(status: :received, received_at: 1.hour.ago)
      failed_job = create_delivery(status: :received, received_at: 1.hour.ago)
      queue_row("ProcessWebhookDeliveryJob", queued.id)
      queue_row("ProcessWebhookDeliveryJob", finished.id, finished_at: 1.minute.ago)
      SolidQueue::FailedExecution.create!(job: queue_row("ProcessWebhookDeliveryJob", failed_job.id), error: "boom")
      queue_row("SendMessageJob", queued.id) # same number, different job class: irrelevant

      described_class.perform_now

      expect(process_jobs.map { |job| job["arguments"].first }).to contain_exactly(finished.id, failed_job.id)
    end

    it "recognizes a job enqueued through the real Solid Queue adapter (its stored argument shape)" do
      delivery = create_delivery(status: :received, received_at: 1.hour.ago)
      real = ActiveJob::QueueAdapters::SolidQueueAdapter.new
      original = ProcessWebhookDeliveryJob.queue_adapter
      begin
        ProcessWebhookDeliveryJob.queue_adapter = real
        ProcessWebhookDeliveryJob.perform_later(delivery.id)
      ensure
        ProcessWebhookDeliveryJob.queue_adapter = original
      end

      described_class.perform_now

      expect(SolidQueue::Job.where(class_name: "ProcessWebhookDeliveryJob").count).to eq(1)
      expect(process_jobs).to be_empty
    end

    it "ends with the delivery processed once even if the original job also runs" do
      Rails.application.config.whatsapp.phone_number_id = nil
      delivery = deliver(meta_fixture("text_greeting"))
      delivery.update_columns(received_at: 10.minutes.ago)
      clear_enqueued_jobs # the original job was lost

      described_class.perform_now
      perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
      ProcessWebhookDeliveryJob.perform_now(delivery.id) # the "lost" job turns up late

      expect(delivery.reload).to have_attributes(status: "processed", attempts: 1)
      expect(Message.outbound.count).to eq(1)
      expect(Message.inbound.count).to eq(1)
    end
  end

  describe "self-healing: deliveries stuck in `processing`" do
    def process_jobs = enqueued_jobs.select { |job| job["job_class"] == "ProcessWebhookDeliveryJob" }

    it "fails a stalled delivery and re-enqueues it while it has had fewer than 3 attempts" do
      [ 0, 1, 2 ].each do |attempts|
        delivery = create_delivery(status: :processing, last_attempted_at: 11.minutes.ago, attempts: attempts)
        clear_enqueued_jobs

        described_class.perform_now

        expect(delivery.reload).to have_attributes(status: "failed", last_error_class: "Stalled")
        expect(process_jobs.map { |job| job["arguments"].first }).to eq([ delivery.id ])
      end
    end

    it "stops retrying a deterministic crasher after 3 attempts and leaves it failed and visible" do
      delivery = create_delivery(status: :processing, last_attempted_at: 11.minutes.ago, attempts: 3)

      described_class.perform_now

      expect(delivery.reload).to have_attributes(status: "failed", last_error_message: "stalled")
      expect(delivery).to be_replayable
      expect(process_jobs).to be_empty
    end

    it "retries automatically all the way: a crash that keeps stalling is attempted exactly 3 times" do
      delivery = deliver(meta_fixture("text_greeting"))
      claims = 0
      allow_any_instance_of(Webhooks::DeliveryProcessor).to receive(:call) do
        claims += 1
        # Simulates a worker that dies after claiming: the delivery is left `processing`.
        raise Interrupt
      end

      4.times do
        begin
          perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
        rescue Interrupt
          nil
        end
        delivery.update_columns(last_attempted_at: 11.minutes.ago)
        described_class.perform_now
      end

      expect(claims).to eq(3)
      expect(delivery.reload).to have_attributes(status: "failed", attempts: 3)
    end

    it "never processes a retried delivery twice" do
      delivery = create_delivery(status: :processing, last_attempted_at: 11.minutes.ago, attempts: 1,
                                 body: meta_fixture("text_greeting"), signature_header: sign(meta_fixture("text_greeting")))

      described_class.perform_now
      perform_enqueued_jobs(only: ProcessWebhookDeliveryJob)
      ProcessWebhookDeliveryJob.perform_now(delivery.id)

      expect(delivery.reload).to have_attributes(status: "processed", attempts: 2)
      expect(Message.outbound.count).to eq(1)
    end
  end

  describe "self-healing: outbound messages stuck in `pending`" do
    include ActiveJob::TestHelper

    def send_jobs = enqueued_jobs.select { |job| job["job_class"] == "SendMessageJob" }

    def stale_pending(minutes_ago)
      create_outbound(status: :pending).tap { |m| m.update_columns(updated_at: minutes_ago.minutes.ago) }
    end

    it "re-enqueues SendMessageJob for a pending message older than 10 minutes" do
      lost = stale_pending(11)
      recent = stale_pending(9)

      described_class.perform_now

      expect(send_jobs.map { |job| job["arguments"].first }).to eq([ lost.id ])
      expect(recent.reload).to be_pending
      expect(lost.reload).to be_pending # the sweeper only enqueues; the job claims
    end

    it "does not touch other statuses and does not pile on when a send job is already queued" do
      queued = stale_pending(30)
      SolidQueue::Job.create!(queue_name: "default", class_name: "SendMessageJob", active_job_id: SecureRandom.uuid,
                              arguments: { "arguments" => [ queued.id ] })
      (Message.statuses.keys - %w[pending sending received]).each { |status| create_outbound(status: status).update_columns(updated_at: 1.day.ago) }

      described_class.perform_now

      expect(send_jobs).to be_empty
    end

    it "never produces a second send, even when the original job and the sweeper's job both run" do
      configure_whatsapp
      customer = create_customer
      open_window(customer.conversation)
      message = create_outbound(status: :pending, customer: customer)
      message.update_columns(updated_at: 11.minutes.ago)
      graph.reply(200, ok_send("wamid.FAKE-SWEEP"))

      described_class.perform_now
      send_jobs.size.times { perform_enqueued_jobs(only: SendMessageJob) } # the sweeper's job
      SendMessageJob.perform_now(message.id) # the "lost" original shows up late
      SendMessageJob.perform_now(message.id)

      expect(graph.calls).to eq(1)
      expect(message.reload).to have_attributes(status: "accepted", attempts: 1)
    end

    it "keeps resolving a stuck `sending` message to unknown, not pending" do
      stuck = create_outbound(status: :sending)
      stuck.update_columns(updated_at: 6.minutes.ago)

      described_class.perform_now

      expect(stuck.reload).to be_unknown
      expect(send_jobs).to be_empty
    end
  end

  it "is scheduled every 5 minutes in production and development" do
    recurring = YAML.safe_load(ERB.new(Rails.root.join("config/recurring.yml").read).result, aliases: true)

    %w[production development].each do |env|
      expect(recurring.dig(env, "stall_sweeper")).to eq("class" => "StallSweeperJob", "schedule" => "every 5 minutes")
    end
  end
end
