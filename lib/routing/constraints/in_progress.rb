# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, у которого нет свободной ёмкости прямо сейчас.
    #
    # «В работе» — это заявки, отправленные провайдеру и ещё не получившие
    # окончательного ответа. У провайдера два независимых предела: по числу
    # одновременных заявок и по их суммарной сумме. Нарушение любого закрывает
    # допуск, поэтому проверяются оба, но причина отсева одна на двоих —
    # различает их текст details с числами.
    #
    # Порядок проверок не случаен: сначала количество, потом сумма. Каскад
    # сохраняет только первую сработавшую причину, и «занято 10 из 10 слотов»
    # объясняет ситуацию лучше, чем упоминание суммы, когда упёрлись оба
    # предела сразу.
    #
    # Эта ёмкость — то, ради чего резерв ставится до ответа провайдера, а не
    # после: пока заявка в полёте, она занимает слот, и следующая заявка
    # обязана это видеть.
    class InProgress < Base
      REASON = 'in_progress_limit_exceeded'

      def self.violation(provider, operation, _state)
        count_violation(provider) || amount_violation(provider, operation)
      end

      def self.count_violation(provider)
        count_limit = provider.in_progress_count_limit
        count = provider.in_progress_count || 0
        return nil if count_limit.nil? || count + 1 <= count_limit

        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'in_progress_count', count, 1, 'in_progress_count_limit', count_limit
          )
        )
      end

      def self.amount_violation(provider, operation)
        amount_limit = provider.in_progress_amount_limit
        amount = provider.in_progress_amount || 0
        return nil if amount_limit.nil? || amount + operation.amount <= amount_limit

        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'in_progress_amount', amount, operation.amount,
            'in_progress_amount_limit', amount_limit
          )
        )
      end

      private_class_method :count_violation, :amount_violation
    end
  end
end
