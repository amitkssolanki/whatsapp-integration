require "rails_helper"

RSpec.describe Ops::Report, "catalog and inbound metrics" do
  let(:from) { Time.utc(2026, 10, 20) }
  let(:to) { Time.utc(2026, 10, 21) }
  let(:t) { Time.utc(2026, 10, 20, 10) }
  let(:report) { described_class.new(from: from, to: to).call }

  def run(kind, status, at, **attrs)
    CatalogSyncRun.create!(kind: kind, status: status, created_at: at, **attrs)
  end

  describe "catalog" do
    it "reports zeros for an empty period" do
      expect(report[:catalog]).to eq(
        push_runs: { "queued" => 0, "submitted" => 0, "succeeded" => 0, "partially_failed" => 0, "failed" => 0 },
        reconcile_runs: { "queued" => 0, "submitted" => 0, "succeeded" => 0, "partially_failed" => 0, "failed" => 0 },
        last_reconcile: {
          found: false, drift_total: 0, drift_pending_push: 0,
          drift_by_type: Ops::CatalogSection::DRIFT_TYPES.to_h { |type| [ type, 0 ] }
        },
        products_dirty: 0
      )
    end

    it "counts runs, takes drift from the latest succeeded reconcile and counts dirty products" do
      run("push", "succeeded", t)
      run("push", "succeeded", t + 1.hour)
      run("push", "failed", t + 2.hours)
      run("push", "queued", from - 1.day)
      run("reconcile", "succeeded", t, result: { "drift" => [ { "type" => "extra_remote", "sku" => "X" } ] })
      run("reconcile", "succeeded", t + 3.hours, result: { "drift" => [
        { "type" => "price_mismatch", "sku" => "A" },
        { "type" => "price_mismatch", "sku" => "B", "pending_push" => true },
        { "type" => "missing_remote", "sku" => "C" }
      ] })
      run("reconcile", "failed", t + 4.hours)

      synced, dirty = create_menu("MAI-006" => 1550, "BEV-001" => 450)
      synced.update_columns(catalog_synced_digest: synced.catalog_digest)
      expect(dirty.catalog_dirty?).to be(true)

      catalog = report[:catalog]

      expect(catalog[:push_runs]).to eq("queued" => 0, "submitted" => 0, "succeeded" => 2, "partially_failed" => 0, "failed" => 1)
      expect(catalog[:reconcile_runs]).to include("succeeded" => 2, "failed" => 1)
      expect(catalog[:last_reconcile]).to include(found: true, drift_total: 3, drift_pending_push: 1)
      expect(catalog[:last_reconcile][:drift_by_type]).to include("price_mismatch" => 2, "missing_remote" => 1, "extra_remote" => 0)
      expect(catalog[:products_dirty]).to eq(1)
    end
  end

  describe "inbound" do
    def inbound(customer, type, at)
      Message.create!(conversation: customer.conversation, direction: :inbound, message_type: type, status: :received, created_at: at)
    end

    it "reports zeros for an empty period" do
      expect(report[:inbound]).to eq(messages: 0, by_type: {}, distinct_customers: 0, customers_without_phone: 0)
    end

    it "counts messages by type and distinct customers, including a BSUID-only customer" do
      with_phone = create_customer
      bsuid_only = Customer.resolve!(wa_user_id: "US.testuser")
      other = create_customer(number: "15550100005")
      inbound(with_phone, "text", t)
      inbound(with_phone, "text", t + 1.minute)
      inbound(bsuid_only, "order", t)
      inbound(other, "text", from - 1.second)
      inbound(other, "text", to)
      create_outbound(customer: with_phone, status: :sent, created_at: t)

      expect(report[:inbound]).to eq(messages: 3, by_type: { "text" => 2, "order" => 1 }, distinct_customers: 2, customers_without_phone: 1)
    end
  end
end
