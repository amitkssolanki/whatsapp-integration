module Admin
  class ConversationsController < BaseController
    LIST_LIMIT = 200

    def index
      @conversations = Conversation.includes(:customer)
        .order(Arel.sql("conversations.last_message_at DESC NULLS LAST"), id: :desc).limit(LIST_LIMIT)
      @message_counts = Message.where(conversation_id: @conversations.map(&:id)).group(:conversation_id).count
    end

    def show
      @conversation = Conversation.includes(:customer).find(params[:id])
      @messages = @conversation.messages.chronological
      @orders = @conversation.customer.orders.order(:id)
    end
  end
end
