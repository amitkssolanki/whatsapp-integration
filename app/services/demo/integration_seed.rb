require "active_support/testing/time_helpers"

module Demo
  # Fills the operator UI with CLEARLY SYNTHETIC traffic, safe to run in
  # production (`bin/rails demo:seed_integration CONFIRM=yes`).
  #
  # It plays a fixed script of customer and Meta behaviour through the REAL app
  # (webhook controller, jobs, state machines), the same way Demo::Simulator
  # does, but in a way that cannot touch real data or Meta:
  #
  #   * everything it creates is flagged `synthetic`: customers ("Demo Customer N",
  #     fake 1 555 010 xxxx numbers), their conversations, messages and orders,
  #     the webhook deliveries (flagged on creation, inside Demo::Sandbox), and the
  #     DEMO-* products. Fake message ids start with "sim." (never "wamid.").
  #   * Demo::Sandbox: WhatsappClient and Catalog::Client talk to an in-process fake,
  #     the credentials and the webhook signing secret are run-local fakes, jobs run
  #     in the foreground in memory (Solid Queue is not used), fault injection is a
  #     process-local override (OpsSetting is never written), Net::HTTP cannot connect.
  #   * it first removes all earlier synthetic data (Demo::SyntheticPurge), so every
  #     run ends with the same counts, and it never selects a non-synthetic row.
  #   * it runs in ONE transaction and verifies the end state (#verify!); if anything
  #     is off, everything (including the reset) is rolled back and it raises.
  #
  # Timestamps are spread over the last few days from a fixed anchor (now, rounded
  # down to the hour) by moving the process clock (travel_to) per step, so the
  # data looks lived in and the 24-hour window logic is exercised for real.
  class IntegrationSeed
    include Plumbing
    include ActiveSupport::Testing::TimeHelpers

    # The end state is not what a clean run guarantees: the transaction was rolled back.
    class Violation < StandardError; end

    CATEGORY_SLUG = "demo-items-synthetic".freeze
    CATEGORY_NAME = "Demo items (synthetic)".freeze
    OPERATOR = "demo-operator".freeze
    NUMBER_PREFIX = "1555010".freeze # the fictional 555-01xx range; numbers are 1555010 + 2001, 2002, ...
    STATUS_GAPS = { "sent" => 2, "delivered" => 6, "read" => 140 }.freeze # seconds after the previous step

    PRODUCTS = [
      { sku: "DEMO-AVAIL-1", name: "Demo Harvest Salad", price_cents: 950, availability: :in_stock,
        description: "Roasted squash, kale, toasted pumpkin seeds and a lemon-tahini dressing. Synthetic demo item." },
      { sku: "DEMO-AVAIL-2", name: "Demo Lentil and Herb Soup", price_cents: 675, availability: :in_stock,
        description: "Slow-cooked green lentils with thyme, carrot and a splash of sherry vinegar. Synthetic demo item." },
      { sku: "DEMO-OOS-1", name: "Demo Roasted Pumpkin Tart", price_cents: 725, availability: :out_of_stock,
        description: "Buttery shortcrust filled with spiced roasted pumpkin. Synthetic demo item, always out of stock." },
      { sku: "DEMO-PRICE-1", name: "Demo Spiced Chai Latte", price_cents: 450, availability: :in_stock,
        description: "Black tea simmered with cardamom, ginger and cinnamon, topped with steamed milk. Synthetic demo item." }
    ].freeze

    Result = Data.define(:scenarios, :counts, :states, :deleted, :fake_requests, :anchor) do
      def passed? = scenarios.all?(&:passed?)
    end

    def self.summary(result)
      lines = [ "SYNTHETIC DATA: every row below is flagged synthetic and excluded from the real metrics. No request left this process " \
                "(#{result.fake_requests} calls answered by the in-process fake). Timestamps run up to #{result.anchor.utc.iso8601}.", "" ]
      lines << "Removed from the previous run: #{result.deleted.map { |table, count| "#{table} #{count}" }.join(', ')}" << ""
      result.scenarios.each do |scenario|
        lines << "#{scenario.passed? ? 'PASS' : 'FAIL'}  #{scenario.title}"
        scenario.checks.reject(&:last).each { |description, _| lines << "        FAIL #{description}" }
      end
      lines << "" << "Created (counts per table):"
      result.counts.each { |table, count| lines << "  #{table}: #{count}" }
      lines << "" << "Per state:"
      result.states.each { |table, states| lines << "  #{table}: #{states.map { |state, count| "#{state} #{count}" }.join(', ')}" }
      lines << "" << "Find them in the admin: customers named \"Demo Customer N\" and the \"synthetic\" badge; remove them with demo:purge_synthetic."
      lines.join("\n")
    end

    def initialize
      @scenarios = []
      @deliveries = []
      @counter = 0
      @queue = InlineQueue.new
      @meta = FakeMeta.new
      @people = {}
    end

    def call
      @started_at = Time.current
      @anchor = @started_at.beginning_of_hour
      result = nil

      # Not joinable: the app's own transactions (one per webhook item, per send
      # record, ...) must still be real savepoints inside it, so that a failed item
      # rolls back on its own exactly as it does in normal operation.
      ActiveRecord::Base.transaction(requires_new: true, joinable: false) do
        @deleted = SyntheticPurge.new.call
        @last_message_id = Message.maximum(:id).to_i
        play
        verify!
        result = Result.new(scenarios: @scenarios, counts: counts, states: states, deleted: @deleted, fake_requests: @meta.calls, anchor: @anchor)
      end
      result
    ensure
      travel_back
    end

    private

    def play
      Sandbox.run(meta: @meta, queue: @queue) do
        AppLog.tagged(simulated: true, synthetic: true) do
          AppLog.event("demo.seed_started")
          create_catalog
          run_scenarios
          Sandbox.assert_isolated!
          AppLog.event("demo.seed_finished", scenarios: @scenarios.size, passed: @scenarios.count(&:passed?))
        end
      end
    end

    # --- identities and the process clock -----------------------------------

    def phone_number_id = Sandbox::PHONE_NUMBER_ID

    def app_secret = Sandbox::APP_SECRET

    def next_id(kind)
      "sim.#{kind}.#{@counter += 1}"
    end

    # "Demo Customer N", created on first use (at the scenario's time).
    def person(index)
      @people[index] ||= begin
        customer = Customer.create!(whatsapp_number: "#{NUMBER_PREFIX}#{2000 + index}", display_name: "Demo Customer #{index}", synthetic: true)
        customer.create_conversation!
        { number: customer.whatsapp_number, name: customer.display_name }
      end
    end

    def start_at(hours_ago)
      @now = @anchor - hours_ago.hours
      travel_to(@now)
    end

    def tick(seconds)
      @now += seconds
      travel_to(@now)
    end

    # --- the script -----------------------------------------------------------

    def create_catalog
      start_at(110)
      category = Category.create!(name: CATEGORY_NAME, slug: CATEGORY_SLUG, position: 99)
      PRODUCTS.each do |attrs|
        Product.create!(attrs.merge(category: category, currency: "USD", synthetic: true, image_url: "https://example.com/demo/#{attrs[:sku].downcase}.jpg"))
      end
    end

    def run_scenarios
      greeting_and_catalog_card(person(1))
      clean_order_accepted(person(1))
      price_mismatch_order(person(2))
      unknown_sku_order(person(3))
      unavailable_order(person(4))
      invalid_quantity_order(person(5))
      permanent_send_failure(person(6))
      ambiguous_send(person(7))
      duplicate_status(person(8))
      replay_after_injected_failure(person(9))
      rejected_order(person(10))
      blocked_outside_window(person(11))
    end

    def greeting_and_catalog_card(who)
      scenario("greeting", "Hi -> catalog card -> read") do
        start_at(96)
        delivery = receive(text_body(who, "Hi"))
        card = outbound(who, "greeting")
        progress(card, through: "read")

        check("the greeting delivery was processed", delivery.processed?)
        check("the reply is an interactive catalog card", card.message_type == "interactive")
        check("the card was read", card.reload.read?)
      end
    end

    def clean_order_accepted(who)
      scenario("clean_order", "Clean order -> receipt delivered/read -> accepted -> notice read") do
        start_at(95)
        delivery = receive(order_body(who, [ line("DEMO-AVAIL-1", 2), line("DEMO-AVAIL-2", 1) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "read")

        tick(15.minutes)
        accepted = order.accept!(by: OPERATOR).ok?
        drain
        notice = outbound(who, "order_accepted")
        progress(notice, through: "read")

        check("the order is clear (no validation issues)", order.reload.clear?)
        check("the operator accepted it", accepted && order.accepted? && order.decided_by == OPERATOR)
        check("the receipt was read", receipt.reload.read?)
        check("the acceptance notice was read", notice.reload.read?)
      end
    end

    def price_mismatch_order(who)
      scenario("price_mismatch", "Price-mismatch order -> needs review") do
        start_at(72)
        delivery = receive(order_body(who, [ line("DEMO-PRICE-1", 1, cents: 400), line("DEMO-AVAIL-1", 1) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")

        check("the order needs review", order.needs_review?)
        check("the issue is price_mismatch", issue_codes(order) == %w[price_mismatch])
        check("the customer's price was honoured", order.order_items.find_by(product_retailer_id: "DEMO-PRICE-1").item_price_cents == 400)
        check("the receipt was delivered", receipt.reload.delivered?)
      end
    end

    def unknown_sku_order(who)
      scenario("unknown_sku", "Order with an unknown SKU -> needs review") do
        start_at(60)
        delivery = receive(order_body(who, [ [ "DEMO-UNKNOWN-1", 1, 999 ] ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "sent")

        check("the order needs review", order.needs_review?)
        check("the issue is unknown_sku", issue_codes(order) == %w[unknown_sku])
        check("the receipt was sent", receipt.reload.sent?)
      end
    end

    def unavailable_order(who)
      scenario("unavailable", "Order for an unavailable product -> needs review") do
        start_at(52)
        delivery = receive(order_body(who, [ line("DEMO-OOS-1", 1) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")

        check("the order needs review", order.needs_review?)
        check("the issue is unavailable", issue_codes(order) == %w[unavailable])
        check("the receipt was delivered", receipt.reload.delivered?)
      end
    end

    def invalid_quantity_order(who)
      scenario("invalid_quantity", "Order with an invalid quantity -> needs review") do
        start_at(46)
        delivery = receive(order_body(who, [ line("DEMO-AVAIL-1", 1), line("DEMO-AVAIL-2", 0) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "read")

        check("the order needs review", order.needs_review?)
        check("the issue is invalid_quantity", issue_codes(order) == %w[invalid_quantity])
        check("only the valid line was kept", order.order_items.pluck(:product_retailer_id) == %w[DEMO-AVAIL-1])
        check("the receipt was read", receipt.reload.read?)
      end
    end

    def permanent_send_failure(who)
      scenario("permanent_failure", "Permanent send failure (131026 recipient undeliverable) -> failed") do
        start_at(38)
        @meta.fail_next(status: 400, code: 131026, title: "Message undeliverable", details: "simulated by the integration seed")
        receive(text_body(who, "Hi"))
        card = outbound(who, "greeting").reload

        check("the message failed", card.failed?)
        check("with Meta's code 131026, categorised recipient_undeliverable", card.error_code == 131026 && card.error_category == "recipient_undeliverable")
        check("after one attempt, with no retry scheduled", card.attempts == 1 && !@queue.scheduled?)
        check("an operator cannot resend it", Message::RESENDABLE_ERROR_CATEGORIES.exclude?(card.error_category))
      end
    end

    def ambiguous_send(who)
      scenario("ambiguous", "Ambiguous send (read timeout) -> left unknown") do
        start_at(30)
        before = @meta.calls
        @meta.timeout_next
        receive(text_body(who, "What are your opening hours?"))
        reply = outbound(who, "reply").reload

        check("the message is unknown", reply.unknown?)
        check("it was sent once and never retried", reply.attempts == 1 && @meta.calls == before + 1 && !@queue.scheduled?)
        check("it has no Meta id and the ambiguous category", reply.wa_message_id.nil? && reply.error_category == "ambiguous")
        check("unknown_at is stamped", reply.unknown_at.present?)
      end
    end

    def duplicate_status(who)
      scenario("duplicate_status", "The same status delivered twice") do
        start_at(26)
        receive(text_body(who, "Hello"))
        card = outbound(who, "greeting")
        progress(card, through: "sent")

        body = status_body(who, card, "delivered")
        tick(6)
        first = post(body)
        drain
        tick(3)
        second = post(body)
        drain

        check("the first delivery applied it", first.reload.outcome["summary"] == { "applied" => 1 })
        check("the second is recorded as a duplicate, not applied again", second.reload.outcome["summary"] == { "duplicate" => 1 })
        check("both deliveries were stored with the same body fingerprint", first.body_sha256 == second.body_sha256 && first.id != second.id)
        check("the message is delivered", card.reload.delivered?)
      end
    end

    def replay_after_injected_failure(who)
      scenario("replay", "Injected processing failure -> replay") do
        start_at(14)
        delivery = nil
        FaultInjection.with_override(%w[processing:order]) do
          delivery = post(order_body(who, [ line("DEMO-AVAIL-2", 2) ]))
          tick(1)
          drain
        end
        failed = delivery.reload.failed?
        detail = delivery.outcome.dig("items", 0, "detail").to_s
        orders_after_failure = Order.where(customer_id: Customer.find_by!(whatsapp_number: who[:number]).id).count

        tick(30.minutes) # an operator notices, fixes the cause and replays
        delivery.replay!(by: OPERATOR)
        drain
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")

        check("the injected failure failed the delivery", failed)
        check("the failure is labeled injected", detail.include?("injected:processing:order") && delivery.reload.injected_faults.include?("injected:processing:order"))
        check("nothing was applied before the replay", orders_after_failure.zero?)
        check("the replay processed it", delivery.processed? && delivery.replay_count == 1)
        check("exactly one order exists after the replay", Order.where(source_message_id: Message.inbound.where(webhook_delivery_id: delivery.id).select(:id)).count == 1)
      end
    end

    def rejected_order(who)
      scenario("rejected", "Clean order -> operator rejects it with a reason") do
        start_at(6)
        delivery = receive(order_body(who, [ line("DEMO-AVAIL-1", 1) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "delivered")

        tick(20.minutes)
        rejected = order.reject!(by: OPERATOR, reason: "kitchen_closed: the demo kitchen closed early").ok?
        drain
        notice = outbound(who, "order_rejected")
        progress(notice, through: "delivered")

        check("the order was rejected with the reason stored", rejected && order.reload.rejected? && order.rejection_reason.to_s.start_with?("kitchen_closed"))
        check("the customer notice was delivered", notice.reload.delivered?)
      end
    end

    def blocked_outside_window(who)
      scenario("blocked", "Send outside the 24h window -> blocked") do
        start_at(100)
        delivery = receive(order_body(who, [ line("DEMO-AVAIL-2", 1) ]))
        order = order_of(delivery)
        receipt = outbound(who, "order_received")
        progress(receipt, through: "read")

        tick(26.hours) # the customer stays silent; the operator gets to it too late
        before = @meta.calls
        accepted = order.accept!(by: OPERATOR).ok?
        drain
        notice = outbound(who, "order_accepted").reload

        check("the operator accepted the order", accepted && order.reload.accepted?)
        check("the notice is blocked: window_closed", notice.blocked? && notice.error_category == "window_closed")
        check("Meta was not called", @meta.calls == before)
      end
    end

    # --- plumbing specific to this script ---------------------------------

    # [sku, quantity, price in cents]: the catalog price unless `cents` says otherwise.
    def line(sku, quantity, cents: nil)
      [ sku, quantity, cents || Product.find_by!(sku: sku).price_cents ]
    end

    # Posts a body, lets the app process it, and returns the stored delivery.
    def receive(body)
      delivery = post(body)
      tick(1)
      drain
      delivery.reload
    end

    def post(body)
      super.tap { |delivery| @deliveries << delivery.id }
    end

    # Runs the queued jobs, then gives the messages they inserted the scenario's time.
    def drain
      super
      retime_messages
    end

    # Message.insert (how the app writes inbound rows and queued replies) stamps
    # created_at and updated_at with the database clock, which the process clock
    # cannot move. Rows are told apart by id, not by time, so clock skew between
    # the app and the database cannot matter.
    def retime_messages
      fresh = synthetic_messages.where("messages.id > ?", @last_message_id)
      newest = fresh.maximum(:id) or return
      fresh.update_all(created_at: @now, updated_at: @now)
      @last_message_id = newest
    end

    # sent -> delivered -> read as separate signed webhooks, up to `through`, a believable time apart.
    def progress(message, through:)
      return unless message.reload.wa_message_id

      STATUS_STEPS.first(STATUS_STEPS.index(through) + 1).each do |status|
        tick(STATUS_GAPS.fetch(status))
        post(status_body({ number: message.conversation.customer.whatsapp_number }, message, status))
        drain
      end
    end

    def order_of(delivery)
      Order.find_by!(source_message: inbound_for(delivery))
    end

    def issue_codes(order)
      order.validation_issues.map { |issue| issue["code"] }
    end

    # --- the end state --------------------------------------------------------

    def synthetic_conversations = Conversation.where(customer_id: Customer.synthetic.select(:id))

    def synthetic_messages = Message.where(conversation_id: synthetic_conversations.select(:id))

    def synthetic_orders = Order.where(customer_id: Customer.synthetic.select(:id))

    # Aborts (and so rolls back the whole run, the reset included) unless every guarantee holds.
    def verify!
      problems = []
      problems.concat(@scenarios.reject(&:passed?).map { |scenario| "scenario #{scenario.key} failed: #{scenario.checks.reject(&:last).map(&:first).join('; ')}" })
      problems.concat(unsettled_messages).concat(queue_problems).concat(network_problems).concat(synthetic_problems)
      raise Violation, "demo:seed_integration rolled everything back:\n  - #{problems.join("\n  - ")}" if problems.any?
    end

    def unsettled_messages
      stuck = synthetic_messages.outbound.where(status: %w[pending sending retry_scheduled]).group(:status).count
      stuck.empty? ? [] : [ "synthetic outbound messages left in-flight: #{stuck.inspect}" ]
    end

    def queue_problems
      found = []
      found << "the in-process queue still holds jobs" unless @queue.empty?
      found << "no job ran in the in-process queue" if @queue.performed.zero?
      found << "Solid Queue holds jobs for this run" if solid_queue_jobs?
      found
    end

    # The run's own deliveries and messages must never appear as Solid Queue jobs
    # (real traffic may create other jobs at the same time; those are not ours).
    def solid_queue_jobs?
      { "ProcessWebhookDeliveryJob" => @deliveries, "SendMessageJob" => synthetic_messages.outbound.pluck(:id) }.any? do |job_class, ids|
        ids.any? && SolidQueue::Job.where(class_name: job_class).where("(arguments::jsonb -> 'arguments' ->> 0) IN (?)", ids.map(&:to_s)).exists?
      end
    end

    def network_problems
      found = []
      found << "a network connection was attempted (#{Sandbox.blocked_connections} blocked)" if Sandbox.blocked_connections.positive?
      found << "Catalog::Client was called" if @meta.catalog_requests.any?
      expected = "/#{Rails.application.config.whatsapp.api_version}/#{Sandbox::PHONE_NUMBER_ID}/messages"
      stray = @meta.requests.reject { |request| request[:path] == expected }
      found << "fake requests for unexpected paths: #{stray.map { |request| request[:path] }.uniq.inspect}" if stray.any?
      found
    end

    def synthetic_problems
      found = []
      found << "some deliveries of this run are not synthetic" if WebhookDelivery.where(id: @deliveries).non_synthetic.exists?
      found << "some customers of this run are not synthetic" if Customer.non_synthetic.where(whatsapp_number: @people.values.map { |who| who[:number] }).exists?
      found << "messages of this run belong to non-synthetic customers" if Message.where(webhook_delivery_id: @deliveries).joins(conversation: :customer).merge(Customer.non_synthetic).exists?
      found << "orders of this run belong to non-synthetic customers" if Order.where(source_message_id: Message.where(webhook_delivery_id: @deliveries).select(:id)).joins(:customer).merge(Customer.non_synthetic).exists?
      found << "some products of this run are not synthetic" if Product.where(sku: PRODUCTS.map { |attrs| attrs[:sku] }).non_synthetic.exists?
      found << "the number of products created is not #{PRODUCTS.size}" unless Product.synthetic.count == PRODUCTS.size
      found
    end

    # --- what the run left ---------------------------------------------------

    def counts
      {
        "products" => Product.synthetic.count,
        "customers" => Customer.synthetic.count,
        "conversations" => synthetic_conversations.count,
        "inbound messages" => synthetic_messages.inbound.count,
        "outbound messages" => synthetic_messages.outbound.count,
        "orders" => synthetic_orders.count,
        "order items" => OrderItem.where(order_id: synthetic_orders.select(:id)).count,
        "webhook deliveries" => WebhookDelivery.synthetic.count
      }
    end

    def states
      {
        "outbound messages" => synthetic_messages.outbound.group(:status).count.sort.to_h,
        "webhook deliveries" => WebhookDelivery.synthetic.group(:status).count.sort.to_h,
        "orders (status/review)" => synthetic_orders.group(:status, :review_status).count.transform_keys { |status, review| "#{status}/#{review}" }.sort.to_h
      }
    end
  end
end
