# frozen_string_literal: true

module Reporting
  # A-4: три раздельных распределения (ARCHITECTURE.md §12).
  #   by_final(..., :count)  -- итоговый selected_provider, доля заявок
  #   by_final(..., :amount) -- итоговый selected_provider, доля объёма
  #   by_attempt              -- все реальные попытки исполнения (decision
  #                              == 'selected'), а не эл. отсев -- нагрузка
  #                              на провайдера и наблюдаемая конверсия.
  module Distributions
    def self.by_final(pairs, providers, weight)
      total = weight == :count ? pairs.size : pairs.sum { |operation, _| operation.amount }

      providers.to_h { |provider| [provider.name, final_entry(pairs, provider, weight, total)] }
    end

    def self.by_attempt(outcomes, providers)
      grouped = real_attempts(outcomes).group_by(&:provider)

      providers.to_h { |provider| [provider.name, attempt_entry(grouped.fetch(provider.name, []))] }
    end

    # A-3/A-5: тальи причин эл. отсева (decision == 'skipped') -- дополняет
    # by_attempt, который считает только реальные попытки исполнения.
    def self.skip_reasons(outcomes)
      outcomes.flat_map(&:attempts)
              .select { |attempt| attempt.decision == 'skipped' }
              .each_with_object(Hash.new(0)) { |attempt, tally| tally[attempt.reason] += 1 }
    end

    def self.final_entry(pairs, provider, weight, total)
      part = weight_of(pairs, provider, weight)
      share_pct = percentage(part, total)
      target_pct = (weight == :count ? provider.traffic_percentage : provider.volume_share_pct) || 0

      {
        (weight == :count ? 'count' : 'amount') => part,
        'share_pct' => share_pct,
        'target_pct' => target_pct,
        'achievable_pct' => target_pct.to_f,
        'deviation_pp' => (share_pct - target_pct).round(1)
      }
    end
    private_class_method :final_entry

    def self.weight_of(pairs, provider, weight)
      pairs.sum do |operation, outcome|
        next 0 unless outcome.selected.name == provider.name

        weight == :count ? 1 : operation.amount
      end
    end
    private_class_method :weight_of

    def self.real_attempts(outcomes)
      outcomes.flat_map(&:attempts).select { |attempt| attempt.decision == 'selected' }
    end
    private_class_method :real_attempts

    def self.attempt_entry(attempts)
      successful = attempts.count { |attempt| attempt.result == 'approved' }

      {
        'attempts' => attempts.size,
        'successful' => successful,
        'observed_conversion' => attempts.empty? ? nil : (successful.to_f / attempts.size).round(3)
      }
    end
    private_class_method :attempt_entry

    def self.percentage(part, total)
      return 0.0 if total.zero?

      (part.to_f / total * 100).round(1)
    end
    private_class_method :percentage
  end
end
