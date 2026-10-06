require "net/http"

module Demo
  # Raised when something that must be isolated is not (a non-fake adapter, a
  # real credential, a queue that is not the in-process one).
  class SandboxViolation < StandardError; end

  # Raised when anything tries to open a network connection while a sandbox is
  # entered.
  class NetworkBlocked < StandardError; end

  # Belt and braces behind the fake adapters: while a sandbox is entered, Net::HTTP
  # (what Faraday's default adapter uses) cannot open a connection at all.
  module NetworkTripwire
    private

    def connect
      raise NetworkBlocked, "a network connection was attempted while a demo sandbox is active" if Demo::Sandbox.entered?

      super
    end
  end

  # A process-local box for synthetic runs (demo:seed_integration). While it is
  # entered, in THIS process only:
  #
  #   * WhatsappClient and Catalog::Client use Demo::FakeMeta's in-process Faraday
  #     adapters, so a request is answered here and can never leave the process
  #   * the credentials are run-local fakes (token, phone number id, app secret),
  #     so a webhook can be signed and verified without the real secret, and the
  #     real token is never used
  #   * every job class uses the given in-memory queue, so Solid Queue is not used
  #   * fault injection is exactly what the run asks for (FaultInjection.with_override);
  #     the stored toggles in the database are neither read nor written
  #   * Net::HTTP cannot connect (NetworkTripwire)
  #
  # Everything is restored afterwards, also when the block raises. Other
  # processes (the web server, the workers) never see any of it.
  #
  # Sends to synthetic customers are refused everywhere EXCEPT where
  # Sandbox.active? is true (see SendMessageJob and WebhookDelivery#replay!).
  # `active?` re-checks the isolation on every call, so swapping any adapter
  # back mid-run makes those guards refuse again.
  module Sandbox
    FAKE_TOKEN = "sim-token-not-real".freeze
    PHONE_NUMBER_ID = "100000000000999".freeze
    APP_SECRET = "sim-app-secret-not-a-real-secret".freeze
    CONFIG_KEYS = %i[token phone_number_id app_secret catalog_id catalog_sync_enabled allow_unsigned].freeze

    class << self
      # Inside `run`.
      def entered? = !@meta.nil?

      # Inside `run` AND still fully isolated.
      def active? = entered? && problems.empty?

      def meta = @meta
      def queue = @queue

      # Raises SandboxViolation unless every isolation property holds right now.
      def assert_isolated!
        raise SandboxViolation, "not inside Demo::Sandbox.run" unless entered?
        raise SandboxViolation, "demo sandbox is not isolated: #{problems.join('; ')}" if problems.any?

        true
      end

      def run(meta:, queue:)
        raise SandboxViolation, "a demo sandbox is already active" if entered?

        install_tripwire
        saved = snapshot
        begin
          @meta = meta
          @queue = queue
          config = Rails.application.config.whatsapp
          config.token = FAKE_TOKEN
          config.phone_number_id = PHONE_NUMBER_ID
          config.app_secret = APP_SECRET
          config.catalog_id = nil
          config.catalog_sync_enabled = false
          config.allow_unsigned = false
          WhatsappClient.adapter = meta.adapter
          Catalog::Client.adapter = meta.catalog_adapter
          job_classes.each { |klass| klass.queue_adapter = queue }

          FaultInjection.with_override([]) do
            assert_isolated!
            yield
          end
        ensure
          leave(saved)
          @meta = nil
          @queue = nil
        end
      end

      # Job classes may carry their own adapter (Rails assigns one per class when
      # they load), so swapping only ActiveJob::Base would miss them.
      def job_classes
        [ ProcessWebhookDeliveryJob, SendMessageJob, CatalogPushJob, CatalogBatchStatusJob, CatalogReconcileJob, StallSweeperJob ] # loaded first, so they are among the descendants
        [ ActiveJob::Base ] + ActiveJob::Base.descendants
      end

      private

      def problems
        config = Rails.application.config.whatsapp
        found = []
        found << "WhatsappClient is not on the fake adapter" unless @meta.owns_whatsapp?(WhatsappClient.adapter)
        found << "Catalog::Client is not on the fake adapter" unless @meta.owns_catalog?(Catalog::Client.adapter)
        found << "the token is not the run-local fake" unless config.token == FAKE_TOKEN
        found << "the phone number id is not the run-local fake" unless config.phone_number_id == PHONE_NUMBER_ID
        found << "the app secret is not the run-local fake" unless config.app_secret == APP_SECRET
        found << "catalog sync is on" if config.catalog_sync_enabled
        stray = job_classes.reject { |klass| klass._queue_adapter.equal?(@queue) }
        found << "#{stray.map(&:name).compact.first(3).join(', ')} not on the in-process queue" if stray.any?
        found
      end

      def snapshot
        config = Rails.application.config.whatsapp
        classes = job_classes
        {
          config: config.to_h.slice(*CONFIG_KEYS),
          whatsapp: WhatsappClient.adapter,
          catalog: Catalog::Client.adapter,
          queues: classes.index_with { |klass| klass._queue_adapter },
          base_queue: ActiveJob::Base.queue_adapter
        }
      end

      def leave(saved)
        config = Rails.application.config.whatsapp
        CONFIG_KEYS.each { |key| saved[:config].key?(key) ? config[key] = saved[:config][key] : config.delete(key) }
        WhatsappClient.adapter = saved[:whatsapp]
        Catalog::Client.adapter = saved[:catalog]
        saved[:queues].each { |klass, adapter| klass.queue_adapter = adapter || saved[:base_queue] }
      end

      def install_tripwire
        Net::HTTP.prepend(NetworkTripwire) unless Net::HTTP.ancestors.include?(NetworkTripwire)
      end
    end
  end
end
