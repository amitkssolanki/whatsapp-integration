class Customer < ApplicationRecord
  has_one :conversation, dependent: :destroy
  has_many :orders, dependent: :nullify

  validates :whatsapp_number, presence: true, uniqueness: true

  # Finds or creates the customer (and its conversation) for an inbound
  # webhook. Safe when two workers see the same new customer at once: the
  # INSERTs use ON CONFLICT DO NOTHING instead of find-then-create, so the
  # loser waits for the winner's commit and reads the winner's row.
  def self.resolve!(whatsapp_number:, display_name: nil, wa_user_id: nil)
    insert({ whatsapp_number: whatsapp_number, display_name: display_name, wa_user_id: wa_user_id },
           unique_by: :whatsapp_number)
    customer = find_by!(whatsapp_number: whatsapp_number)

    fresh = { display_name: display_name.presence, wa_user_id: wa_user_id.presence }.compact
    customer.update!(fresh) if fresh.any? { |attr, value| customer[attr] != value }

    Conversation.insert({ customer_id: customer.id }, unique_by: :customer_id)
    customer
  end
end
