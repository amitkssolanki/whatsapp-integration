class Message < ApplicationRecord
  belongs_to :conversation

  enum :direction, { inbound: 0, outbound: 1 }

  validates :message_type, presence: true

  default_scope { order(:created_at) }
end
