# Delivers one outbound message row to the WhatsApp Cloud API.
class SendMessageJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    # implemented in phase 3
  end
end
