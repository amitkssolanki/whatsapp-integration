require "rails_helper"

RSpec.describe Customer, type: :model do
  describe ".resolve!" do
    it "creates the customer and its conversation on first contact" do
      customer = described_class.resolve!(whatsapp_number: "15550100004", display_name: "Test Customer", wa_user_id: "US.1")

      expect(customer).to have_attributes(display_name: "Test Customer", wa_user_id: "US.1")
      expect(customer.conversation).to be_present
    end

    it "is idempotent and fills in details that arrive later without blanking existing ones" do
      first = described_class.resolve!(whatsapp_number: "15550100004", display_name: "Test Customer")
      again = described_class.resolve!(whatsapp_number: "15550100004", display_name: nil, wa_user_id: "US.1")

      expect(again.id).to eq(first.id)
      expect(again.reload).to have_attributes(display_name: "Test Customer", wa_user_id: "US.1")
      expect([ described_class.count, Conversation.count ]).to eq([ 1, 1 ])
    end
  end
end
