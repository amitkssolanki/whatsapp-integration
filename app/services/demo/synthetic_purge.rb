module Demo
  # Removes exactly the synthetic data, and nothing else: customers flagged
  # `synthetic` with their conversations, messages, orders and order items;
  # deliveries flagged `synthetic`; products flagged `synthetic` (and the demo
  # category once it is empty). It is the reset step of demo:seed_integration
  # and the whole of demo:purge_synthetic, so both delete the same things.
  #
  # One transaction: it either removes everything or nothing. A second run at
  # the same time is refused (advisory lock). Non-synthetic rows are never
  # selected; if one still refers to a synthetic row (which the app never
  # creates) the foreign key stops the whole purge instead of changing it.
  class SyntheticPurge
    class Refused < StandardError; end

    LOCK_KEY = "demo:synthetic".freeze

    # What is there now, as counts (nothing is changed).
    def preview
      {
        customers: customers.count, conversations: conversations.count, messages: messages.count,
        orders: orders.count, order_items: OrderItem.where(order_id: orders.select(:id)).count,
        webhook_deliveries: WebhookDelivery.synthetic.count, products: Product.synthetic.count
      }
    end

    # Deletes everything synthetic and returns what was removed, as counts.
    def call
      counts = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        lock!
        refuse_if_in_use!
        counts = delete_all
      end
      AppLog.event("demo.synthetic_purged", **counts)
      counts
    end

    private

    def customers = Customer.synthetic

    def conversations = Conversation.where(customer_id: customers.select(:id))

    def messages = Message.where(conversation_id: conversations.select(:id))

    def orders = Order.where(customer_id: customers.select(:id))

    def lock!
      query = ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_xact_lock(hashtext(?))", LOCK_KEY ])
      acquired = ActiveRecord::Base.connection.select_value(query)
      raise Refused, "another demo:seed_integration or demo:purge_synthetic is running" unless acquired
    end

    # A real order line must never lose its product (the FK would stop us anyway).
    def refuse_if_in_use!
      in_use = OrderItem.where(product_id: Product.synthetic.select(:id)).where.not(order_id: orders.select(:id))
      raise Refused, "#{in_use.count} order item(s) of non-synthetic orders refer to synthetic products; nothing was removed" if in_use.exists?
    end

    def delete_all
      counts = preview
      # orders.source_message_id and messages.order_id point at each other.
      orders.update_all(source_message_id: nil)
      messages.delete_all
      OrderItem.where(order_id: orders.select(:id)).delete_all
      orders.delete_all
      conversations.delete_all
      customers.delete_all
      WebhookDelivery.synthetic.delete_all
      Product.synthetic.delete_all
      counts[:categories] = Category.unscoped.where(slug: IntegrationSeed::CATEGORY_SLUG).where.not(id: Product.where.not(category_id: nil).select(:category_id)).delete_all
      counts
    end
  end
end
