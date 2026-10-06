module Admin
  # Webhook deliveries as stored. The raw body is never loaded here: it holds
  # phone numbers, names and message text, and the page has no use for it.
  class DeliveriesController < BaseController
    LIST_LIMIT = 100
    ITEM_LIMIT = 100
    SAFE_COLUMNS = (WebhookDelivery.column_names - %w[raw_body]).freeze

    def index
      @filter = WebhookDelivery.statuses.key?(params[:status]) ? params[:status] : "all"
      @counts = WebhookDelivery.group(:status).count
      scope = WebhookDelivery.select(SAFE_COLUMNS).order(received_at: :desc, id: :desc)
      scope = scope.where(status: @filter) unless @filter == "all"
      @deliveries = scope.limit(LIST_LIMIT)
    end

    def show
      @delivery = WebhookDelivery.select(SAFE_COLUMNS).find(params[:id])
      @items = Array(@delivery.outcome["items"]).first(ITEM_LIMIT)
    end

    def replay
      delivery = WebhookDelivery.find(params[:id])
      delivery.replay!(by: current_operator)
      redirect_back_or_to admin_delivery_path(delivery), notice: "Delivery ##{delivery.id} queued for replay."
    rescue WebhookDelivery::ReplayError, ApplicationJob::EnqueueFailed => error
      redirect_back_or_to admin_delivery_path(params[:id]), alert: "Not done: #{Redact.scrub(error.message)}"
    end

    # Replays every delivery that is waiting on an operator (failed or only
    # partly applied) and still has its body. Idempotency keys make each replay safe.
    def replay_failed
      queued = 0
      refused = []
      WebhookDelivery.where(status: %w[failed partially_failed], purged_at: nil).order(:id).find_each do |delivery|
        delivery.replay!(by: current_operator)
        queued += 1
      rescue WebhookDelivery::ReplayError, ApplicationJob::EnqueueFailed => error
        refused << "##{delivery.id}: #{Redact.scrub(error.message)}"
      end

      message = "#{queued} #{'delivery'.pluralize(queued)} queued for replay."
      if refused.empty?
        redirect_back_or_to admin_deliveries_path, notice: message
      else
        redirect_back_or_to admin_deliveries_path, alert: "#{message} Not replayed: #{refused.first(5).join('; ')}"
      end
    end
  end
end
