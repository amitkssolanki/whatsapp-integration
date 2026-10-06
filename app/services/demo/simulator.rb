require "openssl"

module Demo
  class Refused < StandardError; end

  # Plays a fixed script of customer and Meta behaviour through the REAL app
  # (webhook controller, jobs, state machines) so a developer can take
  # screenshots or video of a populated admin UI. Everything it creates is
  # simulated, and marked so:
  #
  #   * customers are "Demo Customer N" with fake +1 555 010 xxxx numbers
  #   * every AppLog event of the run carries simulated=true
  #   * webhook bodies carry "simulated":true and Meta ids start with wamid.DEMO
  #
  # No network: WhatsappClient is pointed at an in-process Faraday adapter
  # (Demo::FakeMeta) whatever token is configured, and statuses arrive as
  # correctly signed POSTs to the real webhook endpoint (signed with a demo app
  # secret that exists only for the run). Jobs run in the foreground
  # (Demo::InlineQueue); no workers needed.
  #
  # Run it with `bin/rails demo:simulate` (development only, separate database;
  # see .refusal). Specs build it with enforce_guard: false.
  class Simulator
    PHONE_NUMBER_ID = "100000000000999".freeze
    APP_SECRET = "demo-app-secret-not-a-real-secret".freeze
    OPERATOR = "demo-operator".freeze
    CUSTOMER_NUMBERS = %w[15550100101 15550100102 15550100103].freeze
    STATUS_STEPS = %w[sent delivered read].freeze
    USAGE = "DATABASE_URL=postgres:///whatsapp_integration_demo bin/rails db:prepare db:seed demo:simulate".freeze

    Scenario = Struct.new(:key, :title, :checks, keyword_init: true) do
      def passed? = checks.all?(&:last)
    end

    Result = Data.define(:scenarios, :totals, :fake_requests, :seed) do
      def passed? = scenarios.all?(&:passed?)
    end

    # nil when this process may run the simulator, otherwise why not.
    def self.refusal(rails_env: Rails.env, env: ENV, database: connected_database)
      return "demo:simulate never runs in production." if rails_env.production?
      return "demo:simulate runs only in development (this is #{rails_env})." unless rails_env.development?
      return nil if env["DATABASE_URL"].to_s.include?("_demo") && database.to_s.include?("_demo")

      "demo:simulate needs its own database so simulated data never mixes with real data: " \
        "DATABASE_URL must name a database containing \"_demo\" (connected to #{database.inspect}).\nRun it as:\n  #{USAGE}"
    end

    def self.connected_database
      ActiveRecord::Base.connection_db_config.database
    end

    def initialize(seed: 1, enforce_guard: true)
      @seed = seed
      @enforce_guard = enforce_guard
      @random = Random.new(seed)
      @scenarios = []
      @counter = 0
    end

    def call
      if @enforce_guard && (reason = self.class.refusal)
        raise Refused, reason
      end

      @products = Product.in_stock.order(:id).limit(3).to_a
      raise Refused, "the simulator needs at least 2 in-stock products; seed the demo database first (#{USAGE})" if @products.size < 2

      @run = Message.inbound.where("wa_message_id LIKE 'wamid.DEMO.%'").count
      @meta = FakeMeta.new(prefix: "wamid.DEMO.out.r#{@run}")
      @queue = InlineQueue.new

      AppLog.tagged(simulated: true) do
        AppLog.event("demo.simulation_started", seed: @seed, run: @run)
        with_demo_environment { run_scenarios }
        AppLog.event("demo.simulation_finished", scenarios: @scenarios.size, passed: @scenarios.count(&:passed?))
      end

      Result.new(scenarios: @scenarios, totals: totals, fake_requests: @meta.calls, seed: @seed)
    end

    def self.summary(result)
      lines = [ "SIMULATED DATA: nothing here is real. No request left this process (#{result.fake_requests} calls answered by the in-process fake).", "" ]
      result.scenarios.each do |scenario|
        lines << "#{scenario.passed? ? 'PASS' : 'FAIL'}  #{scenario.title}"
        scenario.checks.each { |description, ok| lines << "        #{ok ? 'ok  ' : 'FAIL'} #{description}" }
      end
      lines << "" << "Totals (whole database):"
      result.totals.each { |name, value| lines << "  #{name}: #{value}" }
      lines << "" << "Find simulated records: customers named \"Demo Customer N\"; log lines with simulated=true; deliveries whose body has \"simulated\":true."
      lines.join("\n")
    end

    private

    def with_demo_environment
      config = Rails.application.config.whatsapp
      saved_config = config.to_h.slice(:token, :phone_number_id, :app_secret, :catalog_id, :catalog_sync_enabled, :allow_unsigned)
      saved_adapter = WhatsappClient.adapter
      job_classes = self.job_classes
      saved_queues = job_classes.index_with { |klass| klass._queue_adapter }
      base_queue = ActiveJob::Base.queue_adapter
      saved_fault = ENV["FAULT_INJECT"]
      saved_stored_faults = OpsSetting.current.fault_inject

      config.token = "demo-token-not-real"
      config.phone_number_id = PHONE_NUMBER_ID
      config.app_secret = APP_SECRET
      config.catalog_id = nil
      config.catalog_sync_enabled = false
      config.allow_unsigned = false
      WhatsappClient.adapter = @meta.adapter
      job_classes.each { |klass| klass.queue_adapter = @queue }
      ENV.delete("FAULT_INJECT")
      OpsSetting.current.update_columns(fault_inject: []) # toggles stored in this database must not leak into the run

      yield
    ensure
      saved_config&.each { |key, value| config[key] = value }
      WhatsappClient.adapter = saved_adapter if saved_adapter
      saved_queues&.each { |klass, adapter| klass.queue_adapter = adapter || base_queue }
      saved_fault ? ENV["FAULT_INJECT"] = saved_fault : ENV.delete("FAULT_INJECT")
      OpsSetting.current.update_columns(fault_inject: saved_stored_faults) if saved_stored_faults
    end

    # Job classes may carry their own adapter (Rails assigns one per class when
    # they load), so swapping only ActiveJob::Base would miss them.
    def job_classes
      [ ProcessWebhookDeliveryJob, SendMessageJob ] # loaded first so they are among the descendants
      [ ActiveJob::Base ] + ActiveJob::Base.descendants
    end

    # --- the script -------------------------------------------------------

    def run_scenarios
      one, two, three = CUSTOMER_NUMBERS.each_with_index.map { |number, index| { number: number, name: "Demo Customer #{index + 1}" } }

      greeting_and_catalog_card(one)
      clean_order_accepted(one)
      price_drift_order(two)
      unknown_sku_order(two)
      duplicate_status(two)
      replay_after_injected_failure(three)
      retryable_send_failure(three)
      ambiguous_send(three)
      blocked_outside_window(two)
    end

    def greeting_and_catalog_card(who)
      scenario("greeting", "Hi -> catalog card -> read") do
        delivery = post(text_body(who, "Hi"))
        drain
        card = outbound(who, "greeting")
        progress(card, through: "read")
        check("the greeting delivery was processed", delivery.reload.processed?)
        check("the reply is an interactive catalog card", card.message_type == "interactive")
        check("the card was read", card.reload.read?)
      end
    end

    def clean_order_accepted(who)
      scenario("clean_order", "Clean order -> receipt -> delivered/read -> accepted -> notice read") do
        delivery = post(order_body(who, clean_items))
        drain
        order = Order.find_by!(source_message: inbound_for(delivery))
        receipt = outbound(who, "order_received")
        progress(receipt, through: "read")

        accepted = order.accept!(by: OPERATOR).ok?
        drain
        notice = outbound(who, "order_accepted")
        progress(notice, through: "read")

        check("the order is clear (no validation issues)", order.reload.clear?)
        check("the order was accepted by the operator", accepted && order.accepted?)
        check("the receipt was read", receipt.reload.read?)
        check("the acceptance notice was read", notice.reload.read?)
      end
    end

    def price_drift_order(who)
      scenario("price_drift", "Price-drift order -> needs review") do
        first, second = @products
        items = [ [ first.sku, 1, first.price_cents + 150 ], [ second.sku, 1, second.price_cents ] ]
        delivery = post(order_body(who, items))
        drain
        order = Order.find_by!(source_message: inbound_for(delivery))
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")
        @drift_order = order

        check("the order needs review", order.needs_review?)
        check("the issue is price_mismatch", order.validation_issues.any? { |issue| issue["code"] == "price_mismatch" })
        check("the customer's price was honoured", order.order_items.find_by(product_retailer_id: first.sku).item_price_cents == first.price_cents + 150)
        check("the receipt was delivered", receipt.reload.delivered?)
      end
    end

    def unknown_sku_order(who)
      scenario("unknown_sku", "Order with an unknown SKU -> needs review") do
        delivery = post(order_body(who, [ [ "DEMO-UNKNOWN-SKU", 1, 999 ] ]))
        drain
        order = Order.find_by!(source_message: inbound_for(delivery))
        @unknown_receipt = Message.outbound.find_by!(order_id: order.id, purpose: "order_received")
        progress(@unknown_receipt, through: "sent")

        check("the order needs review", order.needs_review?)
        check("the issue is unknown_sku", order.validation_issues.any? { |issue| issue["code"] == "unknown_sku" })
        check("the receipt was sent", @unknown_receipt.reload.sent?)
      end
    end

    def duplicate_status(who)
      scenario("duplicate_status", "The same status delivered twice") do
        body = status_body(who, @unknown_receipt, "delivered")
        first = post(body)
        drain
        second = post(body)
        drain

        check("the first delivery applied it", first.reload.outcome["summary"] == { "applied" => 1 })
        check("the second is recorded as a duplicate, not applied again", second.reload.outcome["summary"] == { "duplicate" => 1 })
        check("both deliveries were stored with the same body fingerprint", first.body_sha256 == second.body_sha256 && first.id != second.id)
        check("the message is delivered", @unknown_receipt.reload.delivered?)
      end
    end

    def replay_after_injected_failure(who)
      scenario("replay", "Injected processing failure -> replay") do
        orders_before = order_count(who)
        ENV["FAULT_INJECT"] = "processing:order"
        delivery = post(order_body(who, clean_items))
        drain
        ENV.delete("FAULT_INJECT")
        failed = delivery.reload.failed?
        detail = delivery.outcome.dig("items", 0, "detail").to_s
        orders_after_failure = order_count(who)

        delivery.replay!(by: OPERATOR)
        drain
        orders_after_replay = order_count(who)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")

        check("the injected failure failed the delivery", failed)
        check("the failure is labeled injected", detail.include?("injected:processing:order"))
        check("nothing was applied before the replay", orders_after_failure == orders_before)
        check("the replay processed it", delivery.reload.processed? && delivery.replay_count == 1)
        check("exactly one order exists after the replay", orders_after_replay == orders_before + 1)
      end
    end

    def retryable_send_failure(who)
      scenario("retry", "Retryable send failure -> succeeds on retry") do
        @meta.fail_next(status: 503, code: 2, title: "Service Unavailable")
        post(text_body(who, "Hi again"))
        drain
        card = outbound(who, "greeting")
        scheduled = card.reload.retry_scheduled?
        @queue.drain(scheduled: true) # the retry delay "passes"
        progress(card, through: "delivered")

        check("the first attempt left it retry_scheduled", scheduled)
        check("the retry succeeded on attempt 2", card.reload.attempts == 2 && card.delivered?)
        check("the failed attempt left no error behind", card.error_category.nil?)
      end
    end

    def ambiguous_send(who)
      scenario("ambiguous", "Ambiguous send (read timeout) -> left unknown") do
        before = @meta.calls
        @meta.timeout_next
        post(text_body(who, "What are your opening hours?"))
        drain
        reply = outbound(who, "reply")

        check("the message is unknown", reply.reload.unknown?)
        check("it was sent exactly once and never retried", reply.attempts == 1 && @meta.calls == before + 1 && !@queue.scheduled?)
        check("it has no Meta id and the ambiguous category", reply.wa_message_id.nil? && reply.error_category == "ambiguous")
        check("unknown_at is stamped", reply.unknown_at.present?)
      end
    end

    def blocked_outside_window(who)
      scenario("blocked", "Send outside the 24h window -> blocked") do
        conversation = Customer.find_by!(whatsapp_number: who[:number]).conversation
        conversation.update_columns(last_inbound_at: 2.days.ago)
        before = @meta.calls

        accepted = @drift_order.accept!(by: OPERATOR).ok?
        drain
        notice = outbound(who, "order_accepted")

        check("the operator accepted the order", accepted && @drift_order.reload.accepted?)
        check("the notice is blocked: window_closed", notice.reload.blocked? && notice.error_category == "window_closed")
        check("Meta was not called", @meta.calls == before)
      end
    end

    # --- plumbing ---------------------------------------------------------

    def scenario(key, title)
      @current = Scenario.new(key: key.to_sym, title: title, checks: [])
      yield
    rescue StandardError => e
      check("ran without raising (#{e.class}: #{Redact.scrub(e.message, limit: 120)})", false)
    ensure
      @scenarios << @current
    end

    def check(description, condition)
      @current.checks << [ description, condition ? true : false ]
    end

    def drain
      @queue.drain
    end

    def clean_items
      @products.first(2).map { |product| [ product.sku, @random.rand(1..3), product.price_cents ] }
    end

    def order_count(who)
      Order.joins(:customer).where(customers: { whatsapp_number: who[:number] }).count
    end

    def outbound(who, purpose)
      conversation = Customer.find_by!(whatsapp_number: who[:number]).conversation
      Message.outbound.where(conversation_id: conversation.id, purpose: purpose).order(:id).last!
    end

    def inbound_for(delivery)
      Message.inbound.find_by!(webhook_delivery_id: delivery.id)
    end

    # sent -> delivered -> read as separate signed webhooks, up to `through`.
    def progress(message, through:)
      return unless message.reload.wa_message_id

      customer = message.conversation.customer
      STATUS_STEPS.first(STATUS_STEPS.index(through) + 1).each do |status|
        post(status_body({ number: customer.whatsapp_number }, message, status))
        drain
      end
    end

    def next_id(kind)
      "wamid.DEMO.#{kind}.r#{@run}.#{@counter += 1}"
    end

    def envelope(value)
      {
        "object" => "whatsapp_business_account",
        "simulated" => true,
        "entry" => [ { "id" => "DEMO-WABA", "changes" => [ {
          "field" => "messages",
          "value" => { "messaging_product" => "whatsapp",
                       "metadata" => { "display_phone_number" => "15550100999", "phone_number_id" => PHONE_NUMBER_ID } }.merge(value)
        } ] } ]
      }
    end

    def inbound_value(who, message)
      {
        "contacts" => [ { "profile" => { "name" => who[:name] }, "wa_id" => who[:number] } ],
        "messages" => [ { "from" => who[:number], "id" => next_id("in"), "timestamp" => Time.current.to_i.to_s }.merge(message) ]
      }
    end

    def text_body(who, text)
      JSON.generate(envelope(inbound_value(who, "type" => "text", "text" => { "body" => text })))
    end

    # items: [[sku, quantity, price_in_cents]]
    def order_body(who, items)
      product_items = items.map do |sku, quantity, cents|
        { "product_retailer_id" => sku, "quantity" => quantity, "item_price" => cents / 100.0, "currency" => "USD" }
      end
      order = { "catalog_id" => "DEMO-CATALOG", "text" => "", "product_items" => product_items }
      JSON.generate(envelope(inbound_value(who, "type" => "order", "order" => order)))
    end

    def status_body(who, message, status)
      JSON.generate(envelope("statuses" => [ {
        "id" => message.wa_message_id, "status" => status, "timestamp" => Time.current.to_i.to_s,
        "recipient_id" => who[:number], "biz_opaque_callback_data" => message.id.to_s
      } ]))
    end

    # POSTs a signed body to the real webhook endpoint, in process, and returns the stored delivery.
    def post(body)
      signature = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', APP_SECRET, body)}"
      session.post "/webhooks/whatsapp", params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => signature }
      raise "the webhook endpoint answered #{session.response.status}" unless session.response.status == 200

      WebhookDelivery.where(body_sha256: Digest::SHA256.hexdigest(body)).order(:id).last!
    end

    def session
      @session ||= ActionDispatch::Integration::Session.new(Rails.application).tap { |session| session.host! "localhost" }
    end

    def totals
      {
        "demo customers" => Customer.where("display_name LIKE 'Demo Customer %'").count,
        "webhook deliveries" => WebhookDelivery.group(:status).count.sort.to_h,
        "inbound messages" => Message.inbound.count,
        "outbound messages" => Message.outbound.group(:status).count.sort.to_h,
        "orders" => Order.group(:status, :review_status).count.transform_keys { |status, review| "#{status}/#{review}" }.sort.to_h
      }
    end
  end
end
