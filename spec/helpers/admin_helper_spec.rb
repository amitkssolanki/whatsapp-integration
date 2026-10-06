require "rails_helper"

RSpec.describe AdminHelper, type: :helper do
  let(:customer) { create_customer }
  let(:conversation) { customer.conversation }

  describe "#duration_words" do
    it "reads as hours and minutes" do
      expect(helper.duration_words(30)).to eq("<1m")
      expect(helper.duration_words(45.minutes)).to eq("45m")
      expect(helper.duration_words(3.hours + 12.minutes)).to eq("3h 12m")
    end
  end

  describe "#ago" do
    let(:now) { Time.utc(2026, 10, 6, 12, 0, 0) }

    it "reads in words, never as a count of hours" do
      expect(helper.ago(now - 20.seconds, now: now)).to include(">less than a minute ago<")
      expect(helper.ago(now - 45.minutes, now: now)).to include(">about 1 hour ago<")
      expect(helper.ago(now - 1.day, now: now)).to include(">1 day ago<")
      expect(helper.ago(now - 1406.hours - 14.minutes, now: now)).to include(">about 2 months ago<")
      expect(helper.ago(now - 1406.hours, now: now)).not_to match(/\d+h \d+m/)
    end

    it "keeps the absolute timestamp in a title attribute" do
      html = helper.ago(Time.utc(2026, 8, 9, 5, 45, 30), now: now)

      expect(html).to include('title="2026-08-09 05:45:30 UTC"')
    end

    it "is a dash for a missing time" do
      expect(helper.ago(nil)).to eq("—")
    end

    it "defaults to the current time" do
      travel_to(now) { expect(helper.ago(now - 3.days)).to include(">3 days ago<") }
    end
  end

  describe "#message_state" do
    it "renders every status with its tick and label" do
      expected = {
        "pending" => [ "⏳", "pending" ], "sending" => [ "⏳", "sending" ],
        "accepted" => [ "✓", "accepted" ], "sent" => [ "✓", "sent" ],
        "delivered" => [ "✓✓", "delivered" ], "read" => [ "✓✓", "read" ],
        "failed" => [ "✕", "failed" ], "blocked" => [ "⛔", "24h window" ],
        "unknown" => [ "?", "outcome unknown" ], "retry_scheduled" => [ "↻", "retry scheduled" ]
      }
      expect(expected.keys).to match_array(Message.statuses.keys - %w[received])

      expected.each do |status, (tick, label)|
        html = helper.message_state(build_message(status))
        expect([ html.include?(tick), html.include?(label) ]).to eq([ true, true ]), "#{status}: #{html}"
      end
    end

    it "shows the error category and title for a failure" do
      html = helper.message_state(build_message("failed", error_category: "auth_config", error_title: "Token expired", error_code: 190))

      expect(html).to include("auth_config").and include("Token expired").and include("code 190")
    end

    it "shows when a retry is due" do
      html = helper.message_state(build_message("retry_scheduled", next_attempt_at: Time.utc(2026, 10, 6, 12, 30, 5), attempts: 2))

      expect(html).to include("next attempt Oct 6, 12:30:05").and include("attempt 2")
    end

    it "marks read as blue and accepted as gray via distinct classes" do
      expect(helper.message_state(build_message("read"))).to include("state-read")
      expect(helper.message_state(build_message("accepted"))).to include("state-accepted")
    end

    def build_message(status, **attrs)
      Message.new({ status: status, direction: :outbound, message_type: "text" }.merge(attrs))
    end
  end

  describe "#window_header and #window_badge" do
    let(:now) { Time.utc(2026, 10, 6, 12, 0) }

    it "reports an open window with the time left" do
      conversation.update!(last_inbound_at: now - 20.hours)

      expect(helper.window_header(conversation, now: now)).to eq("Window open until 15:55 (3h 55m left)")
      expect(helper.window_badge(conversation, now: now)).to include("window open").and include("3h 55m left")
    end

    it "reports a closed window with when it closed" do
      conversation.update!(last_inbound_at: now - 30.hours)

      expect(helper.window_header(conversation, now: now)).to eq("Window closed at Oct 6, 05:55")
      expect(helper.window_badge(conversation, now: now)).to include("window closed")
    end

    it "treats a customer who never wrote as closed" do
      expect(helper.window_header(conversation, now: now)).to include("never written")
    end
  end
end
