module Ops
  # Small aggregate helpers shared by the report sections. Everything here is a
  # count or a duration summary, so nothing identifying can pass through.
  module Stats
    module_function

    # Every expected key present (0 when nothing happened), string keys; keys
    # outside `keys` are kept.
    def zero_filled(keys, tally)
      keys.to_h { |key| [ key.to_s, 0 ] }.merge(tally.transform_keys(&:to_s))
    end

    # Count of each value, nil/blank shown as `blank`.
    def tally(values, blank: "none")
      values.map { |value| value.presence&.to_s || blank }.tally
    end

    # {n:, median:, min:, max:} for a list of numbers. Medians only: with small
    # samples a percentile would be noise. An empty sample is n: 0 with nil
    # statistics (there is no honest number to show).
    def summary(values, digits: 2)
      sorted = values.compact.sort
      return { n: 0, median: nil, min: nil, max: nil } if sorted.empty?

      middle = sorted.size / 2
      median = sorted.size.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
      { n: sorted.size, median: median.to_f.round(digits), min: sorted.first.to_f.round(digits), max: sorted.last.to_f.round(digits) }
    end

    # Seconds between two timestamps, for each [from, to] pair where both exist.
    def seconds_between(pairs)
      pairs.filter_map { |from, to| (to - from).to_f if from && to }
    end
  end
end
