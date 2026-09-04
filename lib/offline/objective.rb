# frozen_string_literal: true

require_relative 'metrics'

module Offline
  module Objective
    SCALE = 10_000
    BASIS_POINTS_PER_PERCENT = 100

    def self.metrics(counts:, delivered:, providers:, total:)
      normalized_counts = providers.to_h do |provider|
        [provider.name, counts.fetch(provider.name, 0)]
      end
      max_deviation_num = providers.map do |provider|
        ((normalized_counts.fetch(provider.name) * SCALE) - (target_bp(provider) * total)).abs
      end.max || 0

      Metrics.new(max_deviation_num, delivered, total, normalized_counts)
    end

    def self.deviations_pp(counts:, providers:, total:)
      providers.to_h do |provider|
        numerator = (counts.fetch(provider.name, 0) * SCALE) - (target_bp(provider) * total)
        [provider.name,
         total.zero? ? 0.0 : Rational(numerator, total * BASIS_POINTS_PER_PERCENT).to_f.round(1)]
      end
    end

    def self.from_pairs(pairs, providers:)
      counts = providers.to_h { |provider| [provider.name, 0] }
      delivered = 0
      pairs.map(&:last).each do |outcome|
        counts[outcome.selected.name] += 1
        delivered += 1 unless outcome.result == :rejected
      end
      metrics(counts: counts, delivered: delivered, providers: providers, total: pairs.size)
    end

    def self.target_bp(provider)
      provider.traffic_percentage.to_i * BASIS_POINTS_PER_PERCENT
    end
    private_class_method :target_bp
  end
end
