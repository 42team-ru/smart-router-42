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
    #
    # Как и DailyLimit#approved_amount: если передано состояние прогона,
    # счётчики берутся из него, а не из снимка провайдера — снимок не знает
    # про резервы, которые сама очередь уже поставила. Без состояния (офлайн-
    # расчёт, Routing::Achievable, Reporting) считается по снимку, как раньше.
    class InProgress < Base
      REASON = 'in_progress_limit_exceeded'

      def self.violation(provider, operation, state)
        count_violation(provider, state) || amount_violation(provider, operation, state)
      end

      def self.count_violation(provider, state)
        count_limit = provider.in_progress_count_limit
        count = live_count(provider, state)
        return nil if count_limit.nil? || count + 1 <= count_limit

        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'in_progress_count', count, 1, 'in_progress_count_limit', count_limit
          )
        )
      end

      def self.amount_violation(provider, operation, state)
        amount_limit = provider.in_progress_amount_limit
        amount = live_amount(provider, state)
        return nil if amount_limit.nil? || amount + operation.amount <= amount_limit

        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'in_progress_amount', amount, operation.amount,
            'in_progress_amount_limit', amount_limit
          )
        )
      end

      def self.live_count(provider, state)
        return state.in_progress_count(provider.name) if state.respond_to?(:in_progress_count)

        provider.in_progress_count || 0
      end

      def self.live_amount(provider, state)
        return state.in_progress_amount(provider.name) if state.respond_to?(:in_progress_amount)

        provider.in_progress_amount || 0
      end

      private_class_method :count_violation, :amount_violation, :live_count, :live_amount
    end
  end
end
