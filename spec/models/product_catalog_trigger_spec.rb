require "rails_helper"

RSpec.describe "Product catalog sync trigger" do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:category) { Category.create!(name: "Menu", slug: "menu") }
  let!(:product) do
    Product.create!(name: "Margherita", sku: "MAI-006", price_cents: 1550, category: category)
  end

  context "when catalog sync is enabled" do
    before do
      configure_catalog!(sync: true)
      clear_enqueued_jobs
    end

    it "enqueues a debounced push on create" do
      freeze_time do
        expect { Product.create!(name: "Tea", sku: "BEV-001", price_cents: 450, category: category) }
          .to have_enqueued_job(CatalogPushJob).with(no_args).at(30.seconds.from_now)
      end
    end

    %i[name description price_cents currency availability image_url sku].each do |attribute|
      it "enqueues a push when #{attribute} changes" do
        value = {
          name: "Renamed", description: "New text", price_cents: 1600, currency: "EUR",
          availability: :out_of_stock, image_url: "https://example.com/new.jpg", sku: "MAI-007"
        }.fetch(attribute)
        expect { product.update!(attribute => value) }.to have_enqueued_job(CatalogPushJob)
      end
    end

    it "does not enqueue for changes Meta never sees" do
      expect { product.update!(catalog_sync_error: "x", catalog_synced_digest: "abc", brand: "Other") }
        .not_to have_enqueued_job(CatalogPushJob)
      expect { product.touch }.not_to have_enqueued_job(CatalogPushJob)
    end

    it "does not enqueue for a save that changes nothing" do
      expect { product.update!(name: product.name) }.not_to have_enqueued_job(CatalogPushJob)
    end

    it "does not enqueue when the transaction rolls back" do
      expect do
        Product.transaction do
          product.update!(price_cents: 1)
          raise ActiveRecord::Rollback
        end
      end.not_to have_enqueued_job(CatalogPushJob)
    end

    it "does not trigger from the job's own bookkeeping writes" do
      expect { product.update_columns(catalog_synced_digest: product.catalog_digest, catalog_synced_at: Time.current) }
        .not_to have_enqueued_job(CatalogPushJob)
    end
  end

  context "when catalog sync is disabled" do
    before do
      configure_catalog!(sync: false)
      clear_enqueued_jobs
    end

    it "never enqueues, even for a relevant change" do
      expect { product.update!(price_cents: 1600) }.not_to have_enqueued_job(CatalogPushJob)
      expect { Product.create!(name: "Tea", sku: "BEV-001", price_cents: 450, category: category) }
        .not_to have_enqueued_job(CatalogPushJob)
    end
  end

  describe Catalog::SyncNow do
    include ActiveJob::TestHelper

    it "enqueues an immediate push tagged with the operator when sync is enabled" do
      configure_catalog!(sync: true)
      result = nil
      expect { result = described_class.call(by: "admin") }
        .to have_enqueued_job(CatalogPushJob).with(full: false, triggered_by: "admin")
      expect(result).to be_enqueued
    end

    it "can force a full push" do
      configure_catalog!(sync: true)
      expect { described_class.call(by: "admin", full: true) }
        .to have_enqueued_job(CatalogPushJob).with(full: true, triggered_by: "admin")
    end

    it "reports why nothing was enqueued when sync is disabled" do
      configure_catalog!(sync: false)
      result = nil
      expect { result = described_class.call(by: "admin") }.not_to have_enqueued_job(CatalogPushJob)
      expect(result).not_to be_enqueued
      expect(result.reason).to include("CATALOG_SYNC_ENABLED")
    end
  end
end
