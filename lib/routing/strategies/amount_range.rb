# frozen_string_literal: true

require_relative '../strategies'

module Routing
  module Strategies
    # Ранжирует по полосам суммы чека: у каждой суммы свой предпочтительный
    # провайдер.
    #
    # Правило вида «500–50 000 отдаём payflow, свыше 100 000 — quickpay»
    # выражает знание о том, кто на каком чеке работает лучше: у одного дешевле
    # мелкие переводы, у другого выше проходимость крупных. Провайдер, чья
    # полоса совпала с суммой, поднимается наверх; остальные упорядочиваются
    # по приоритету.
    #
    # Важно, чем это отличается от одноимённой проверки допуска
    # Constraints::AmountRange. Та отвечает «возьмёт ли провайдер такую сумму
    # вообще» и отсекает. Эта отвечает «кому из тех, кто возьмёт, отдать
    # предпочтительнее» и только двигает порядок. Оба механизма существуют
    # намеренно: предпочтение не должно превращаться в запрет, иначе заявка,
    # не попавшая ни в одну полосу, осталась бы без исполнителя.
    #
    # Полосы приходят из конфига через from_config — сам класс файлов не
    # открывает, конфиг читает только bin/route. Формат полосы — сырой YAML со
    # строковыми ключами: {"from"=>500, "to"=>50000, "prefer"=>"payflow"};
    # отсутствующая граница означает, что с этой стороны полоса открыта.
    #
    # По умолчанию полос нет — и это не забывчивость, а отказ от второй копии
    # тех же чисел: продублируй их здесь, и они разъехались бы с конфигом
    # молча. Без полос стратегия честно вырождается в порядок по приоритету.
    class AmountRange < Base
      def initialize(ranges: [])
        super()
        @ranges = ranges
      end

      def self.from_config(config) = new(ranges: config.amount_ranges)

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
