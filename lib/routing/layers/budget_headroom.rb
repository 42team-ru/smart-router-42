# frozen_string_literal: true

require_relative '../layers'
require_relative 'base'

module Routing
  module Layers
    # BALANCE из AdWords: провайдер с исчерпывающимся дневным бюджетом получает
    # положительное отклонение и уступает кандидатам с достаточным headroom.
    class BudgetHeadroom < Base
      MICRO = 1_000_000
      TAYLOR_TERMS = 16
      DEFAULT_PSI_THRESHOLD_MICRO = 100_000
      CONFIG_KEY = 'psi_threshold_micro'

      def self.from_config(config)
        goals = config.goals.fetch('budget_headroom', {})
        new(psi_threshold_micro: goals.fetch(CONFIG_KEY, DEFAULT_PSI_THRESHOLD_MICRO))
      end

      def initialize(psi_threshold_micro: DEFAULT_PSI_THRESHOLD_MICRO)
        super()
        validate_threshold!(psi_threshold_micro)
        @psi_threshold_micro = psi_threshold_micro
      end

      def name = 'budget_headroom'

      def psi_micro(provider, state)
        limit = provider.daily_amount_limit
        return MICRO if limit.nil? || limit <= 0

        x = 1 - Rational(live_daily_approved(provider, state), limit)
        x = 0 if x.negative?
        ((1 - taylor_exp_neg(x)) * MICRO).round
      end

      def deviation(provider, _operation, state)
        [0, psi_threshold_micro - psi_micro(provider, state)].max
      end

      def explain(ranked_before, ranked_after, _operation, state)
        minimum = ranked_before.map { |provider| psi_micro(provider, state) }.min
        return no_reordering_details(minimum) if ranked_before == ranked_after

        reordered_details(ranked_before, ranked_after, state)
      end

      private

      attr_reader :psi_threshold_micro

      def live_daily_approved(provider, state)
        if state.respond_to?(:daily_approved_amount)
          return state.daily_approved_amount(provider.name)
        end

        provider.daily_approved_amount.to_i
      end

      def taylor_exp_neg(value)
        term = Rational(1, 1)
        sum = term
        1.upto(TAYLOR_TERMS - 1) do |n|
          term *= -value
          term /= n
          sum += term
        end
        sum
      end

      def no_reordering_details(minimum)
        "#{name}: без перестановки, минимальный psi #{format_micro(minimum)}; " \
          "порог #{format_micro(psi_threshold_micro)}"
      end

      def reordered_details(ranked_before, ranked_after, state)
        after_positions = positions(ranked_after)
        providers = ranked_before.each_with_index.map do |provider, index|
          provider_details(provider, index, after_positions, state)
        end
        "#{name}: #{providers.join('; ')}; порог #{format_micro(psi_threshold_micro)}"
      end

      def positions(ranked)
        ranked.each_with_index.to_h { |provider, index| [provider.name, index + 1] }
      end

      def provider_details(provider, index, after_positions, state)
        psi = psi_micro(provider, state)
        deviation_value = deviation(provider, nil, state)
        "#{provider.name} psi #{format_micro(psi)} (отклонение #{deviation_value}) " \
          "-> с #{index + 1} на #{after_positions.fetch(provider.name)}"
      end

      def format_micro(value)
        return '1.000' if value == MICRO

        format('0.%03d', (value + 500) / 1000)
      end

      def validate_threshold!(value)
        return if value.is_a?(Integer) && value.between?(0, MICRO)

        raise ArgumentError,
              "goals.budget_headroom.#{CONFIG_KEY} must be Integer 0..#{MICRO}, " \
              "got #{value.inspect}"
      end
    end

    register('budget_headroom', BudgetHeadroom)
  end
end
