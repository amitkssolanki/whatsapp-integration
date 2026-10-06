require "rails_helper"

RSpec.describe Demo::Sandbox do
  let(:meta) { Demo::FakeMeta.new }
  let(:queue) { Demo::InlineQueue.new }

  def sandboxed(&block) = described_class.run(meta: meta, queue: queue, &block)

  it "is not entered, and not active, outside a run" do
    expect(described_class.entered?).to be(false)
    expect(described_class.active?).to be(false)
    expect { described_class.assert_isolated! }.to raise_error(Demo::SandboxViolation, /not inside/)
  end

  it "puts every external dependency of this process on in-process fakes, and restores them afterwards" do
    config = Rails.application.config.whatsapp
    config.token = "real-looking-token"
    config.phone_number_id = "123456789"
    config.catalog_id = "CAT1"
    config.catalog_sync_enabled = true
    config.allow_unsigned = true
    whatsapp_adapter = WhatsappClient.adapter
    catalog_adapter = Catalog::Client.adapter
    job_adapter = SendMessageJob._queue_adapter

    sandboxed do
      expect(described_class).to be_entered
      expect(described_class).to be_active
      expect(meta.owns_whatsapp?(WhatsappClient.adapter)).to be(true)
      expect(meta.owns_catalog?(Catalog::Client.adapter)).to be(true)
      expect(config).to have_attributes(token: described_class::FAKE_TOKEN, phone_number_id: described_class::PHONE_NUMBER_ID,
                                        app_secret: described_class::APP_SECRET, catalog_id: nil, catalog_sync_enabled: false, allow_unsigned: false)
      expect(SendMessageJob._queue_adapter).to equal(queue)
      expect(ProcessWebhookDeliveryJob._queue_adapter).to equal(queue)
    end

    expect(described_class).not_to be_entered
    expect(config).to have_attributes(token: "real-looking-token", phone_number_id: "123456789", catalog_id: "CAT1", catalog_sync_enabled: true,
                                      allow_unsigned: true, app_secret: TEST_APP_SECRET)
    expect(WhatsappClient.adapter).to equal(whatsapp_adapter)
    expect(Catalog::Client.adapter).to equal(catalog_adapter)
    expect(SendMessageJob._queue_adapter).to equal(job_adapter)
  end

  it "restores everything when the block raises" do
    expect { sandboxed { raise "boom" } }.to raise_error("boom")

    expect(described_class).not_to be_entered
    expect(WhatsappClient.adapter).to eq(graph.adapter)
    expect(Rails.application.config.whatsapp.token).to be_nil
    expect(FaultInjection.active).to eq([])
  end

  it "cannot be nested" do
    sandboxed { expect { sandboxed { } }.to raise_error(Demo::SandboxViolation, /already active/) }

    expect(described_class).not_to be_entered
  end

  it "stops being active, and fails the hard assertion, as soon as any adapter is swapped back" do
    sandboxed do
      WhatsappClient.adapter = graph.adapter
      expect(described_class).not_to be_active
      expect { described_class.assert_isolated! }.to raise_error(Demo::SandboxViolation, /WhatsappClient is not on the fake adapter/)
    end
    sandboxed do
      Catalog::Client.adapter = [ :net_http ]
      expect { described_class.assert_isolated! }.to raise_error(Demo::SandboxViolation, /Catalog::Client is not on the fake adapter/)
    end
    sandboxed do
      Rails.application.config.whatsapp.token = "the-real-token"
      expect { described_class.assert_isolated! }.to raise_error(Demo::SandboxViolation, /token/)
    end
    sandboxed do
      SendMessageJob.queue_adapter = :async
      expect { described_class.assert_isolated! }.to raise_error(Demo::SandboxViolation, /SendMessageJob.*in-process queue/)
    end
  end

  it "blocks Net::HTTP from connecting while entered (nothing is dialled, whatever the adapter)" do
    sandboxed do
      expect { Net::HTTP.new("graph.facebook.com", 443).start }.to raise_error(Demo::NetworkBlocked)
    end
  end

  it "controls fault injection only through the process-local override, never through OpsSetting" do
    OpsSetting.current.update!(fault_inject: %w[send:5xx], updated_by: "operator")
    ENV["FAULT_INJECT"] = "processing:order"

    sandboxed do
      expect(FaultInjection.active).to eq([])
      FaultInjection.with_override(%w[processing:order]) { expect(FaultInjection.active).to eq(%w[processing:order]) }
      expect(FaultInjection.active).to eq([])
    end

    expect(OpsSetting.current).to have_attributes(fault_inject: %w[send:5xx], updated_by: "operator")
    expect(FaultInjection.active).to eq(%w[send:5xx processing:order])
  end
end

RSpec.describe "Rows created inside a Demo::Sandbox" do
  let(:meta) { Demo::FakeMeta.new }
  let(:body) { '{"object":"whatsapp_business_account","entry":[]}' }

  def ingest = Webhooks::Ingest.new(raw_body: body, signature_header: sign(body), request_id: "t").call

  it "are synthetic by construction: deliveries and customers, whoever creates them" do
    inside_delivery = inside_customer = nil
    Demo::Sandbox.run(meta: meta, queue: Demo::InlineQueue.new) do
      inside_delivery = ingest
      inside_customer = Customer.resolve!(whatsapp_number: "15550103999", display_name: "Anyone")
    end

    expect(inside_delivery.reload.synthetic).to be(true)
    expect(inside_customer.reload.synthetic).to be(true)
  end

  it "are real outside a sandbox, and an existing real customer is left alone inside one" do
    real = Customer.resolve!(whatsapp_number: "15550100123", display_name: "Real")
    expect(ingest.reload.synthetic).to be(false)

    Demo::Sandbox.run(meta: meta, queue: Demo::InlineQueue.new) { Customer.resolve!(whatsapp_number: "15550100123") }

    expect(real.reload.synthetic).to be(false)
  end
end
