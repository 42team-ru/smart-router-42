# frozen_string_literal: true

require_relative '../layers'
require_relative 'base'

module Routing
  module Layers
    # Придерживает провайдера, который уже перебрал свою целевую долю.
    #
    # Цель односторонняя, и в этом всё отличие от стратегии CountShare. Та
    # старается подтянуть отстающих и вывести распределение к целевому с обеих
    # сторон. Этот слой молчит, пока провайдер не превысил свою долю, и
    # включается только на превышении — «недобор» его не интересует вовсе.
    #
    # Зачем отдельный механизм, если доли уже считает стратегия: стратегию
    # можно сменить на любую другую — по конверсии, по загрузке, по приоритету,
    # — и тогда следить за потолком долей станет некому. Слой навешивается
    # поверх любой стратегии и удерживает одно конкретное обязательство, не
    # мешая ей делать свою работу.
    #
    # Допуск задаётся порогом терпимости: по умолчанию ноль — любое превышение
    # считается превышением. Ненулевой порог позволяет мириться с небольшим
    # перекосом там, где дёргать порядок дороже, чем потерпеть.
    #
    # Величина превышения считается в базисных пунктах через умножение, без
    # деления, и сравнима только между кандидатами ОДНОЙ заявки: у всех них
    # общий знаменатель — сколько заявок роздано на этот момент. Сравнивать эти
    # числа между разными заявками бессмысленно.
    class ShareCeiling < Base
      BASIS_POINTS = 10_000
      DEFAULT_TOLERANCE_BP = 0
      CONFIG_KEY = 'tolerance_bp'

      def self.from_config(config)
        goals = config.goals.fetch('share_ceiling', {})
        new(tolerance_bp: goals.fetch(CONFIG_KEY, DEFAULT_TOLERANCE_BP))
      end

      def initialize(tolerance_bp: DEFAULT_TOLERANCE_BP)
        super()
        validate_tolerance!(tolerance_bp)
        @tolerance_bp = tolerance_bp
      end

      def name = 'share_ceiling'

      def deviation(provider, _operation, state)
        total = state.total_count_units
        return 0 if total.zero? || provider.traffic_percentage.nil?

        excess = (BASIS_POINTS * state.count_units(provider)) -
                 (provider.traffic_percentage * 100 * total)
        excess > tolerance_bp * total ? excess : 0
      end

      def explain(ranked_before, ranked_after, _operation, state)
        if ranked_before == ranked_after
          return "#{name}: без перестановки, максимальное превышение " \
                 "#{maximum_excess_bp(ranked_before, state)} bp"
        end

        after_positions = positions(ranked_after)
        details = ranked_before.each_with_index.map do |provider, index|
          provider_details(provider, index, after_positions, state)
        end
        "#{name}: #{details.join('; ')}"
      end

      private

      attr_reader :tolerance_bp

      def positions(ranked)
        ranked.each_with_index.to_h { |provider, index| [provider.name, index + 1] }
      end

      def provider_details(provider, index, after_positions, state)
        total = state.total_count_units
        taken = state.count_units(provider)
        excess = deviation(provider, nil, state)
        "#{provider.name} #{taken} из #{total} при цели #{provider.traffic_percentage || 0}% " \
          "(превышение #{excess_bp(excess, total)} bp) -> с #{index + 1} на " \
          "#{after_positions.fetch(provider.name)}"
      end

      def excess_bp(excess, total)
        return 0 if total.zero?

        (excess + total - 1) / total
      end

      def maximum_excess_bp(providers, state)
        total = state.total_count_units
        providers.map { |provider| excess_bp(deviation(provider, nil, state), total) }.max || 0
      end

      def validate_tolerance!(value)
        return if value.is_a?(Integer) && value.between?(0, BASIS_POINTS)

        raise ArgumentError,
              "goals.share_ceiling.#{CONFIG_KEY} must be Integer 0..#{BASIS_POINTS}, " \
              "got #{value.inspect}"
      end
    end

    register('share_ceiling', ShareCeiling)
  end
end
