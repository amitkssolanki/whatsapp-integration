class Customer < ApplicationRecord
  has_one :conversation, dependent: :destroy
  has_many :orders, dependent: :nullify

  validates :whatsapp_number, presence: true, uniqueness: true

  # Finds the customer for an inbound webhook, creating one (and its
  # conversation) on first contact.
  def self.find_or_create_by_whatsapp_number!(number, display_name: nil)
    customer = find_or_create_by!(whatsapp_number: number) do |c|
      c.display_name = display_name
    end
    customer.create_conversation! unless customer.conversation
    customer
  end
end
