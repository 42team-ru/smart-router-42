# frozen_string_literal: true

module Reporting
  module TargetFeasibility
    def self.build(pairs, providers, achievable)
      average = if pairs.empty?
                  0
                else
                  Rational(pairs.sum do |operation, _|
                    operation.amount
                  end, pairs.size)
                end
      providers.select { |provider| achievable.key?(provider.name) }.to_h do |provider|
        [provider.name, entry(pairs.size, average, provider, achievable.fetch(provider.name))]
      end
    end

    def self.entry(total, average, provider, achievable)
      target = Rational(total * provider.traffic_percentage.to_i, 100).ceil
      capacity = capacity_operations(provider, average)
      feasible = capacity.nil? || capacity >= target
      { 'target_operations' => target, 'capacity_operations' => capacity,
        'achieved_operations' => achievable.fetch(:achievable_seats), 'feasible' => feasible,
        'explanation' => explanation(provider.name, target, capacity, feasible) }
    end
    private_class_method :entry

    def self.capacity_operations(provider, average)
      return nil if provider.daily_amount_limit.nil? || average.zero?

      [(provider.daily_amount_limit - (provider.daily_approved_amount || 0)) / average, 0].max.floor
    end
    private_class_method :capacity_operations

    def self.explanation(name, target, capacity, feasible)
      return "цель #{target} заявок для #{name} достижима" if feasible

      "цель #{target} заявок для #{name} НЕДОСТИЖИМА: остатка лимита хватает на #{capacity}"
    end
    private_class_method :explanation
  end
end
