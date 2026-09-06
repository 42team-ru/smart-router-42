# frozen_string_literal: true

# rubocop:disable Layout/LineLength

module Reporting
  module OutcomesSummary
    RESULTS = %i[approved rejected expired].freeze

    def self.build(pairs, history)
      counts = counts_for(pairs)
      { **counts.transform_keys(&:to_s), 'success_rate_pct' => percentage(counts[:approved], pairs.size),
                                         'expected_success_rate_pct' => expected_rate(pairs, history),
                                         'avg_latency_sec' => average_latency(pairs), 'by_provider' => by_provider(pairs) }
    end

    def self.counts_for(pairs)
      RESULTS.to_h do |result|
        [result, pairs.count do |_operation, outcome|
          outcome.result == result
        end]
      end
    end
    private_class_method :counts_for

    def self.by_provider(pairs)
      pairs.group_by { |_operation, outcome| outcome.selected.name }.sort.to_h do |name, entries|
        [name, counts_for(entries).transform_keys(&:to_s)]
      end
    end
    private_class_method :by_provider

    def self.expected_rate(pairs, history)
      return 0.0 if pairs.empty?

      (pairs.sum do |_operation, outcome|
        history.approved_bp(outcome.selected.name)
      end.to_f / pairs.size / 100).round(1)
    end
    private_class_method :expected_rate

    def self.average_latency(pairs)
      values = pairs.filter_map { |_operation, outcome| outcome.selected.avg_latency_sec }
      values.empty? ? nil : (values.sum.to_f / values.size).round(2)
    end
    private_class_method :average_latency

    def self.percentage(part, total)
      return 0.0 if total.zero?

      (part.to_f * 100 / total).round(1)
    end
    private_class_method :percentage
  end
end
# rubocop:enable Layout/LineLength
