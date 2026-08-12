module Admin
  class ConversationsController < ApplicationController
    def index
      @conversations = Conversation.includes(:customer, :messages).order(last_message_at: :desc, created_at: :desc)
    end

    def show
      @conversation = Conversation.includes(:customer, :messages).find(params[:id])
    end
  end
end
