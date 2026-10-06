require "rails_helper"

# Real threads, real commits (see spec/requests/webhooks/concurrency_spec.rb).
RSpec.describe Customer, "concurrent resolution" do
  self.use_transactional_tests = false

  def truncate_all
    abort "refusing to truncate outside the test environment" unless Rails.env.test?

    ActiveRecord::Base.connection.truncate_tables(*%w[order_items orders messages conversations customers])
  end

  before { truncate_all }
  after { truncate_all }

  def resolve_in_threads(*identities)
    barrier = Queue.new
    identities.map do |identity|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier << true
          Customer.transaction { Customer.resolve!(**identity).tap { |customer| customer.fill_in!(**identity) } }
        end
      end
    end.map(&:value)
  end

  it "ends with one customer and one conversation when the same new customer arrives in several shapes at once" do
    10.times do |round|
      number = "1555010#{round.to_s.rjust(4, '0')}"
      user_id = "US.#{round}"

      resolved = resolve_in_threads(
        { whatsapp_number: number, wa_user_id: user_id },
        { whatsapp_number: number },
        { whatsapp_number: number, wa_user_id: user_id, display_name: "Racer" },
        { whatsapp_number: number }
      )

      expect(resolved.map(&:id).uniq.size).to eq(1)
    end

    expect(Customer.count).to eq(10)
    expect(Conversation.count).to eq(10)
    expect(Customer.where(wa_user_id: nil).count).to eq(0)
  end
end
