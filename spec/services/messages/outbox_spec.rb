require "rails_helper"

RSpec.describe Messages::Outbox, type: :model do
  include ActiveJob::TestHelper

  let(:conversation) { create_customer.conversation }
  let(:reply) { Conversations::Responder::Reply.new(purpose: "reply", idempotency_key: "reply:1", message_type: "text", body: "hi", request: { "type" => "text", "body" => "hi" }) }

  it "inserts one pending row and one job per idempotency key" do
    first = described_class.queue(conversation: conversation, reply: reply)
    again = described_class.queue(conversation: conversation, reply: reply)

    expect(first).to be_present
    expect(again).to be_nil
    expect(Message.outbound.count).to eq(1)
    expect(enqueued_jobs.size).to eq(1)
  end

  it "raises when the job cannot be enqueued, so the caller's transaction rolls the row back" do
    allow(SendMessageJob).to receive(:perform_later).and_return(false)

    expect do
      Message.transaction { described_class.queue(conversation: conversation, reply: reply) }
    end.to raise_error(ApplicationJob::EnqueueFailed)

    expect(Message.outbound.count).to eq(0)
  end
end
