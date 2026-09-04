# frozen_string_literal: true

require_relative '../strategies'
require_relative '../../io/history_loader'

module Routing
  module Strategies
    # S-5: по НАБЛЮДАЕМОЙ конверсии (калибровка IO-3 из operations_history.csv),
    # убыванием — не по паспортному conversion_24h из providers.json, который
    # заявлен продавцом и не совпадает с фактом (см. docs/ARCHITECTURE.md §12).
    #
    # Значения хранятся в целых промилле, сравнение — обычный <=> без float:
    # общий знаменатель 1000 у всех значений, кросс-умножение не требуется.
    class Conversion < Base
      HISTORY_PATH = File.expand_path('../../../reference/data/operations_history.csv', __dir__)

      def initialize(observed: self.class.default_observed)
        super()
        @observed = observed
      end

      def self.default_observed
        @default_observed ||= Io::HistoryLoader.load(HISTORY_PATH)
      end

      def rank(candidates, _operation, _state)
        candidates.sort { |left, right| compare(left, right) }
      end

      def name = 'conversion'

      def explain(ranked, _operation, _state)
        winner = ranked.first
        winner_text = "#{winner.name} #{permille(winner)}‰"
        return "conversion: #{winner_text}, других допустимых нет" if ranked.one?

        other = ranked[1]
        "conversion: #{winner_text} против #{other.name} #{permille(other)}‰"
      end

      private

      def compare(left, right)
        left_value = permille(left)
        right_value = permille(right)
        return -1 if left_value > right_value
        return 1 if left_value < right_value

        left.name <=> right.name
      end

      def permille(provider)
        (@observed.fetch(provider.name, 0.0) * 1000).round
      end
    end

    register('conversion', Conversion)
  end
end
