# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Layout/LineLength

module Reporting
  # Экономика только для approved: сравнение сделанного выбора с лучшим и
  # худшим допустимым кандидатом данной операции, а не с недостижимым паспортом.
  module CostEfficiency
    def self.build(pairs, providers, eligibility)
      index = providers.to_h { |provider| [provider.name, provider] }
      values = pairs.filter_map do |operation, outcome|
        entry(operation, outcome, index, eligibility)
      end
      earned = values.sum { |value| value[:earned] }
      best = values.sum { |value| value[:best] }
      worst = values.sum { |value| value[:worst] }
      { 'approved_operations' => values.size, 'margin_earned' => earned,
        'best_possible_margin' => best, 'worst_possible_margin' => worst,
        'missed_margin' => best - earned, 'vs_best_pct' => percent(earned, best) }
    end

    def self.entry(operation, outcome, index, eligibility)
      return nil unless outcome.result == :approved

      candidates = eligibility.fetch(operation.operation_id, []).filter_map { |name| index[name] }
      return nil if candidates.empty?

      margins = candidates.map { |provider| margin(operation.amount, provider) }
      selected = index[outcome.selected.name]
      return nil if selected.nil?

      { earned: margin(operation.amount, selected), best: margins.max, worst: margins.min }
    end
    private_class_method :entry

    def self.margin(amount, provider)
      (amount * ((provider.merchant_margin_pct || 0) - (provider.provider_margin_pct || 0)) * 100).round / 100.0
    end
    private_class_method :margin

    def self.percent(value, total)
      return nil if total.zero?

      (value.to_f * 100 / total).round(1)
    end
    private_class_method :percent
  end
end
# rubocop:enable Metrics/AbcSize, Layout/LineLength
