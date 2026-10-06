require "rails_helper"

RSpec.describe Customer, type: :model do
  describe ".resolve!" do
    it "creates the customer and its conversation on first contact" do
      customer = described_class.resolve!(whatsapp_number: "15550100004", display_name: "Test Customer", wa_user_id: "US.1")

      expect(customer).to have_attributes(display_name: "Test Customer", wa_user_id: "US.1", whatsapp_number: "15550100004")
      expect(customer.conversation).to be_present
    end

    # What the webhook handler does for a message it has just applied; a duplicate
    # message resolves but never refreshes (see "does not touch an existing customer").
    def see(**identity) = described_class.resolve!(**identity).tap { |customer| customer.fill_in!(**identity) }

    it "is idempotent and fills in details that arrive later without blanking existing ones" do
      first = described_class.resolve!(whatsapp_number: "15550100004", display_name: "Test Customer")
      again = see(whatsapp_number: "15550100004", display_name: nil, wa_user_id: "US.1")

      expect(again.id).to eq(first.id)
      expect(again.reload).to have_attributes(display_name: "Test Customer", wa_user_id: "US.1")
      expect([ described_class.count, Conversation.count ]).to eq([ 1, 1 ])
    end

    it "does not touch an existing customer: a duplicate or replayed old message must not overwrite newer data" do
      customer = described_class.resolve!(whatsapp_number: "15550100004", wa_user_id: "US.1", display_name: "New Name")
      customer.update_columns(updated_at: 1.day.ago)

      again = described_class.resolve!(whatsapp_number: "15550100004", wa_user_id: "US.1", display_name: "Old Name")
      described_class.resolve!(wa_user_id: "US.1", display_name: "Older Name")

      expect(again.reload).to have_attributes(display_name: "New Name")
      expect(again.updated_at).to be < 1.hour.ago
    end

    it "refreshes the display name only through fill_in!, and never blanks it" do
      customer = described_class.resolve!(whatsapp_number: "15550100004", display_name: "First")

      customer.fill_in!(display_name: "Second")
      expect(customer.reload.display_name).to eq("Second")

      customer.fill_in!(display_name: nil)
      customer.fill_in!(display_name: "")
      expect(customer.reload.display_name).to eq("Second")
    end

    it "never overwrites an identifier it already has" do
      customer = described_class.resolve!(whatsapp_number: "15550100004", wa_user_id: "US.1")

      customer.fill_in!(whatsapp_number: "15550100099", wa_user_id: "US.2")

      expect(customer.reload).to have_attributes(whatsapp_number: "15550100004", wa_user_id: "US.1")
    end

    it "refuses a message with neither identifier" do
      expect { described_class.resolve!(whatsapp_number: nil, wa_user_id: " ") }.to raise_error(ArgumentError, /phone number or a user id/)
      expect(described_class.count).to eq(0)
    end

    describe "identity by business-scoped user id" do
      it "creates a customer from a user id alone" do
        customer = described_class.resolve!(wa_user_id: "US.7", display_name: "No Phone")

        expect(customer).to have_attributes(whatsapp_number: nil, wa_user_id: "US.7", display_name: "No Phone")
        expect(customer.conversation).to be_present
      end

      it "finds the same customer by user id even when the phone number differs or is absent" do
        first = described_class.resolve!(whatsapp_number: "15550100004", wa_user_id: "US.7")

        expect(described_class.resolve!(wa_user_id: "US.7").id).to eq(first.id)
        expect(described_class.resolve!(whatsapp_number: "15550100099", wa_user_id: "US.7").id).to eq(first.id)
        expect(first.reload.whatsapp_number).to eq("15550100004") # identifiers are never overwritten
        expect(described_class.count).to eq(1)
      end

      it "fills in the phone number when a later message brings it" do
        first = described_class.resolve!(wa_user_id: "US.7")
        again = see(whatsapp_number: "15550100004", wa_user_id: "US.7")

        expect(again.id).to eq(first.id)
        expect(again.reload.whatsapp_number).to eq("15550100004")
      end

      it "fills in the user id when a phone-only customer is seen again with one" do
        first = described_class.resolve!(whatsapp_number: "15550100004")
        again = see(whatsapp_number: "15550100004", wa_user_id: "US.7")

        expect(again.id).to eq(first.id)
        expect(again.reload.wa_user_id).to eq("US.7")
      end

      it "keeps two identifiers that belong to different customers apart instead of crashing or merging" do
        by_phone = described_class.resolve!(whatsapp_number: "15550100004")
        by_user = described_class.resolve!(wa_user_id: "US.7")

        resolved = see(whatsapp_number: "15550100004", wa_user_id: "US.7")

        expect(resolved.id).to eq(by_user.id) # the user id wins
        expect(by_user.reload.whatsapp_number).to be_nil # the phone belongs to another row
        expect(by_phone.reload.wa_user_id).to be_nil
        expect(described_class.count).to eq(2)
      end

      it "survives an identifier conflict inside the caller's transaction" do
        described_class.resolve!(whatsapp_number: "15550100004")
        by_user = described_class.resolve!(wa_user_id: "US.7")

        described_class.transaction do
          see(whatsapp_number: "15550100004", wa_user_id: "US.7")
          expect(described_class.where(id: by_user.id).count).to eq(1) # the transaction is still usable
        end
      end
    end

    describe "database constraints" do
      it "rejects a row with neither identifier" do
        expect { described_class.insert_all([ { display_name: "ghost" } ]) }.to raise_error(ActiveRecord::StatementInvalid, /customers_identity_present/)
      end

      it "allows many phone-less and many user-id-less customers but no duplicates of a present value" do
        described_class.insert_all([ { wa_user_id: "A" }, { wa_user_id: "B" } ])
        described_class.insert_all([ { whatsapp_number: "1" }, { whatsapp_number: "2" } ])

        expect { described_class.transaction(requires_new: true) { described_class.insert_all!([ { wa_user_id: "A" } ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
        expect { described_class.transaction(requires_new: true) { described_class.insert_all!([ { whatsapp_number: "1" } ]) } }.to raise_error(ActiveRecord::RecordNotUnique)
      end
    end

    it "validates that at least one identifier is present" do
      expect(described_class.new(display_name: "x")).not_to be_valid
      expect(described_class.new(wa_user_id: "US.1")).to be_valid
    end
  end
end
