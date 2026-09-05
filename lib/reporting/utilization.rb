# frozen_string_literal: true

module Reporting
  # projected_daily_utilization -- дневная сумма из снимка провайдера (уже
  # одобрено до этой партии) плюс сумма заявок партии, одобренных этому
  # провайдеру.
  module Utilization
    def self.projected_daily(pairs, providers)
      providers.to_h { |provider| [provider.name, entry(pairs, provider)] }
    end

    def self.entry(pairs, provider)
      used = (provider.daily_approved_amount || 0) + batch_approved(pairs, provider)
      limit = provider.daily_amount_limit
      utilization_pct = limit.nil? || limit.zero? ? nil : (used.to_f / limit * 100).round(1)

      { 'used' => used, 'limit' => limit, 'utilization_pct' => utilization_pct }
    end
    private_class_method :entry

    def self.batch_approved(pairs, provider)
      pairs.sum do |operation, outcome|
        next 0 unless outcome.selected.name == provider.name && outcome.result == :approved

        operation.amount
      end
    end
    private_class_method :batch_approved
  end
end
