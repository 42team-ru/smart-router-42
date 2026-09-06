# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по полосам суммы чека: у каждой суммы свой предпочтительный
    # провайдер («500–50 000 — payflow, свыше 100 000 — quickpay»). Провайдер,
    # чья полоса совпала с суммой, поднимается наверх, остальные идут по
    # приоритету.
    #
    # Не путать с Constraints::AmountRange: та отсекает по лимитам провайдера,
    # эта только двигает порядок допущенных. Предпочтение не должно
    # превращаться в запрет, иначе заявка вне всех полос осталась бы без
    # исполнителя.
    #
    # Полосы приходят из конфига через from_config; формат — сырой YAML со
    # строковыми ключами {"from"=>500, "to"=>50000, "prefer"=>"payflow"},
    # отсутствующая граница означает открытую с этой стороны полосу.
    #
    # По умолчанию полос нет: дублировать числа конфига здесь значило бы
    # разъехаться с ним молча. Без полос стратегия вырождается в приоритет.
    class AmountRange < Base
      def initialize(ranges: [])
        super()
        @ranges = ranges
      end

      # Реестр передаёт всем стратегиям одинаковый набор именованных аргументов;
      # этой нужен только config, остальное поглощается.
      def self.from_config(config, **_rest) = new(ranges: config.amount_ranges)

      def rank(candidates, operation, _state)
        preferred = preferred_name(operation.amount)
        candidates.sort { |left, right| compare(left, right, preferred) }
      end

      def name = 'amount_range'

      def explain(ranked, operation, _state)
        preferred = preferred_name(operation.amount) || 'никого'
        winner = ranked.first
        text = "amount_range: #{operation.amount}, полоса за #{preferred}, первый #{winner.name}"
        return text if ranked.one?

        "#{text}, второй #{ranked[1].name}"
      end

      private

      def compare(left, right, preferred)
        left_tier = tier(left, preferred)
        right_tier = tier(right, preferred)
        return left_tier <=> right_tier if left_tier != right_tier
        return left.priority <=> right.priority if left.priority != right.priority

        left.name <=> right.name
      end

      def tier(provider, preferred) = provider.name == preferred ? 0 : 1

      def preferred_name(amount)
        band = @ranges.find { |range| in_band?(range, amount) }
        band && band['prefer']
      end

      def in_band?(range, amount)
        from = range['from']
        to = range['to']
        (from.nil? || amount >= from) && (to.nil? || amount <= to)
      end
    end

    register('amount_range', AmountRange)
  end
end
