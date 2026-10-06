require "rails_helper"

# Real threads, real commits: transactional fixtures would hide the very
# locking this spec exists to exercise, so they are off here and the tables
# are emptied afterwards.
RSpec.describe "Concurrent processing of the same inbound message", type: :request do
  self.use_transactional_tests = false

  def truncate_all
    abort "refusing to truncate outside the test environment" unless Rails.env.test?

    ActiveRecord::Base.connection.truncate_tables(
      *%w[order_items orders messages conversations customers webhook_deliveries products categories]
    )
  end

  before do
    truncate_all
    create_menu
  end

  after { truncate_all }

  it "creates exactly one message, one order and one reply, however the workers interleave" do
    body = meta_fixture("order")
    # Two deliveries of the same logical message (different bytes, as Meta's duplicate posts can be).
    deliveries = [ deliver(body), deliver(body.sub("{", "{ ")) ]

    # Hold the winner inside its transaction long enough that the other worker
    # reaches the INSERT while the first row is still uncommitted.
    slow = true
    allow_any_instance_of(Orders::Builder).to receive(:call).and_wrap_original do |original|
      sleep 0.4 if slow
      slow = false
      original.call
    end

    ready = Queue.new
    threads = deliveries.each_with_index.map do |delivery, index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          sleep 0.15 * index
          ProcessWebhookDeliveryJob.perform_now(delivery.id)
        end
      end
    end
    threads.each(&:join)

    expect(Message.inbound.count).to eq(1)
    expect(Order.count).to eq(1)
    expect(OrderItem.count).to eq(3)
    expect(Message.outbound.count).to eq(1)
    expect(Customer.count).to eq(1)

    results = deliveries.map { |d| d.reload.outcome["items"].map { |item| item["result"] } }
    expect(results).to contain_exactly([ "applied" ], [ "duplicate" ])
    expect(deliveries.map(&:status)).to all(eq("processed"))
    expect(enqueued_jobs.count { |job| job["job_class"] == "SendMessageJob" }).to eq(1)
  end
end
