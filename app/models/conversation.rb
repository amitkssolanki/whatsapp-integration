class Conversation < ApplicationRecord
  belongs_to :customer
  has_many :messages, dependent: :destroy

  def record_message!(direction:, message_type:, body: nil, wa_message_id: nil, raw_payload: {})
    transaction do
      messages.create!(
        direction: direction,
        message_type: message_type,
        body: body,
        wa_message_id: wa_message_id,
        raw_payload: raw_payload
      ).tap { touch(:last_message_at) }
    end
  end
end
