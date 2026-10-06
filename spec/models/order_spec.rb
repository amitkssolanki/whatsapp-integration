require "rails_helper"

RSpec.describe Order, type: :model do
  def build_in_status(status) = create_order(status: status)

  it_behaves_like "a state machine"

  it "makes accepted and rejected terminal" do
    expect(described_class::ALLOWED_TRANSITIONS.keys).to eq(%w[received])
  end

  it "records who decided and why in the transition" do
    order = create_order
    order.transition!(:rejected, decided_at: Time.current, decided_by: "operator", rejection_reason: "sold out")

    expect(order.reload).to have_attributes(status: "rejected", decided_by: "operator", rejection_reason: "sold out")
  end

  it "keeps V1 status integers: 0 is received and 1 is accepted (was confirmed)" do
    expect(described_class.statuses).to include("received" => 0, "accepted" => 1, "rejected" => 2)
  end

  it "keeps review_status independent of status" do
    order = create_order(review_status: :needs_review)

    expect { order.transition!(:accepted) }.not_to change { order.reload.review_status }
  end
end
