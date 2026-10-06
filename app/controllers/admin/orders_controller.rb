module Admin
  class OrdersController < BaseController
    LIST_LIMIT = 200
    FILTERS = %w[all needs_review received accepted rejected].freeze
    REJECTION_REASONS = {
      "out_of_stock" => "Out of stock",
      "kitchen_closed" => "Kitchen closed",
      "cannot_fulfil" => "Cannot fulfil",
      "other" => "Other"
    }.freeze

    def index
      @filter = FILTERS.include?(params[:filter]) ? params[:filter] : "all"
      @counts = FILTERS.index_with { |filter| filtered(filter).count }
      @orders = filtered(@filter).includes(:customer, :order_items, :messages).order(created_at: :desc, id: :desc).limit(LIST_LIMIT)
    end

    def show
      @order = Order.includes(:customer, order_items: :product).find(params[:id])
      @conversation = @order.customer.conversation
      @notifications = @order.messages.chronological
    end

    def accept
      order = Order.find(params[:id])
      result = order.accept!(by: current_operator)

      respond(order, result, "Order ##{order.id} accepted; the customer notification is queued.")
    end

    def reject
      order = Order.find(params[:id])
      code = params[:reason].to_s
      return redirect_to(admin_order_path(order), alert: "Choose a rejection reason.") unless REJECTION_REASONS.key?(code)

      result = order.reject!(by: current_operator, reason: [ code, params[:note].to_s.strip.presence ].compact.join(": "))

      respond(order, result, "Order ##{order.id} rejected; the customer notification is queued.")
    end

    private

    def filtered(filter)
      case filter
      when "needs_review" then Order.received.needs_review
      when "all" then Order.all
      else Order.public_send(filter)
      end
    end

    def respond(order, result, success)
      if result.ok?
        redirect_to admin_order_path(order), notice: success
      else
        redirect_to admin_order_path(order), alert: "Not done: #{result.reason}"
      end
    end
  end
end
