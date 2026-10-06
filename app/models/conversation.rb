class Conversation < ApplicationRecord
  belongs_to :customer
  has_many :messages, dependent: :destroy
end
