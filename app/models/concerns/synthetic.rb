# Rows that are clearly synthetic: created by `demo:seed_integration` so the
# operator UI is not empty, never by a real customer or the real catalog.
# The app keeps them away from Meta (SendMessageJob, Catalog push, replay) and
# out of the real metrics (Ops::Report). The `synthetic` column is the single
# source of truth; see docs/operating/PROTOCOL.md.
module Synthetic
  extend ActiveSupport::Concern

  included do
    scope :synthetic, -> { where(synthetic: true) }
    scope :non_synthetic, -> { where(synthetic: false) }
  end
end
