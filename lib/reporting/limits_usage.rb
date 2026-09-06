# frozen_string_literal: true

# rubocop:disable Metrics/MethodLength, Layout/LineLength

module Reporting
  module LimitsUsage
    RESULTS = %i[approved rejected expired].freeze

    def self.build(pairs, providers)
      providers.to_h { |provider| [provider.name, entry(pairs, provider)] }
    end

    def self.entry(pairs, provider)
      selected = pairs.select { |_operation, outcome| outcome.selected.name == provider.name }
      counts = RESULTS.to_h do |result|
        [result.to_s, selected.count do |_op, outcome|
          outcome.result == result
        end]
      end
      { 'routed' => selected.size, **counts, 'daily_approved_amount' => provider.daily_approved_amount,
        'daily_amount_limit' => provider.daily_amount_limit,
        'available_requisites' => provider.available_requisites,
        'requests_per_minute_limit' => provider.requests_per_minute_limit,
        'avg_latency_sec' => provider.avg_latency_sec }
    end
    private_class_method :entry
  end
end
# rubocop:enable Metrics/MethodLength, Layout/LineLength
