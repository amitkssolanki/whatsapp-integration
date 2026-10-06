# Forward-only state changes that are safe under concurrency.
#
# The host model declares an integer `enum :status` and an ALLOWED_TRANSITIONS
# hash ({ "from" => %w[to ...] }). `transition!` then issues a single
#
#   UPDATE ... SET status = :to, ... WHERE id = :id AND status IN (:allowed_from)
#
# so the database, not the Ruby object in memory, decides who wins. A false
# return means the row was not in an allowed state (usually because another
# worker got there first) and callers treat it as a no-op.
#
# Hosts may add per-edge conditions through TRANSITION_GUARDS:
#   { %w[from to] => { column => allowed_values } }
module StatusTransitions
  extend ActiveSupport::Concern

  class_methods do
    # States from which `to` may be entered.
    def transition_sources(to)
      self::ALLOWED_TRANSITIONS.select { |_from, targets| targets.include?(to.to_s) }.keys
    end

    def transition_allowed?(from, to)
      self::ALLOWED_TRANSITIONS.fetch(from.to_s, []).include?(to.to_s)
    end
  end

  def transition!(to, **attrs)
    to = to.to_s
    raise ArgumentError, "unknown #{self.class.name} status: #{to}" unless self.class.statuses.key?(to)

    sources = self.class.transition_sources(to)
    return false if sources.empty?

    updated = self.class.where(id: id).and(allowed_source_scope(sources, to))
      .update_all(attrs.merge(status: self.class.statuses.fetch(to), updated_at: Time.current))

    return false if updated.zero?

    reload
    true
  end

  private

  def allowed_source_scope(sources, to)
    guards = self.class.const_defined?(:TRANSITION_GUARDS) ? self.class::TRANSITION_GUARDS : {}

    sources.map { |from|
      self.class.where(status: from).where(guards.fetch([ from, to ], {}))
    }.reduce(:or)
  end
end
