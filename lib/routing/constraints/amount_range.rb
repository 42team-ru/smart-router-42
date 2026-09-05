# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, который не работает с такой суммой чека.
    #
    # У каждого провайдера свой рабочий диапазон: мелкие переводы невыгодны
    # из-за фиксированной комиссии, крупные упираются в его собственные
    # договорённости с банком. Проверка отвечает только на вопрос «возьмёт ли
    # он такую сумму вообще».
    #
    # Единственная проверка допуска с двумя разными причинами отсева: слишком
    # мало и слишком много — разные ситуации, и в attempts они должны читаться
    # по-разному. Границы независимы: nil в любой из них означает, что с этой
    # стороны ограничения нет. Обе границы включительные — сумма, равная
    # лимиту, проходит.
    #
    # Не путать со стратегией Strategies::AmountRange: та работает с полосами
    # сумм из конфига и влияет на порядок уже допущенных. Здесь — жёсткий
    # отсев по лимитам самого провайдера, и одно другое не заменяет.
    class AmountRange < Base
      MIN_REASON = 'amount_below_minimum'
      MAX_REASON = 'amount_exceeds_limit'

      def self.violation(provider, operation, _state)
        min = provider.limit_amount_min
        if !min.nil? && operation.amount < min
          return Violation.new(
            reason: MIN_REASON,
            details: Details.below_min(operation.amount, min)
          )
        end

        max = provider.limit_amount_max
        return nil if max.nil? || operation.amount <= max

        Violation.new(reason: MAX_REASON, details: Details.above_max(operation.amount, max))
      end
    end
  end
end
