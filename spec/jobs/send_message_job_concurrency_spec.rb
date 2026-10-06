require "rails_helper"

# Real threads, real commits: transactional fixtures would serialise the two
# workers on one connection and hide the race the claim exists to win.
RSpec.describe SendMessageJob, "claim race", type: :job do
  self.use_transactional_tests = false

  def truncate_all
    abort "refusing to truncate outside the test environment" unless Rails.env.test?

    ActiveRecord::Base.connection.truncate_tables(*%w[order_items orders messages conversations customers])
  end

  before do
    truncate_all
    configure_whatsapp
  end

  after { truncate_all }

  it "sends exactly once when several workers pick up the same pending message" do
    message = create_outbound(customer: create_customer)
    open_window(message.conversation)
    5.times { graph.reply(200, ok_send("wamid.FAKE-RACE")) { sleep 0.3 } } # more replies than any correct run needs

    threads = 5.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          sleep 0.02 * index
          described_class.perform_now(message.id)
        end
      end
    end
    threads.each(&:join)

    expect(graph.calls).to eq(1)
    expect(message.reload).to have_attributes(status: "accepted", attempts: 1, wa_message_id: "wamid.FAKE-RACE")
  end

  it "lets only one of two workers claim a retry_scheduled message" do
    message = create_outbound(customer: create_customer, status: :retry_scheduled, attempts: 1)
    open_window(message.conversation)
    2.times { graph.reply(200, ok_send("wamid.FAKE-RACE2")) { sleep 0.2 } }

    2.times.map { |i| Thread.new { ActiveRecord::Base.connection_pool.with_connection { sleep 0.01 * i; described_class.perform_now(message.id) } } }.each(&:join)

    expect(graph.calls).to eq(1)
    expect(message.reload.attempts).to eq(2)
  end
end
