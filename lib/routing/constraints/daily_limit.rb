# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, которому заявка не влезает в дневной лимит.
    #
    # Считает сумму после назначения: одобрено за день плюс сумма заявки против
    # лимита. Равенство лимиту проходит.
    #
    # «Одобрено» берётся из состояния прогона, когда оно передано: за очередь мы
    # сами могли отдать провайдеру несколько заявок, снапшот об этом не знает.
    # Без состояния (офлайн-расчёты) — из снапшота.
    class DailyLimit < Base
      REASON = 'daily_limit_exceeded'

      def self.violation(provider, operation, state)
        limit = provider.daily_amount_limit
        return nil if limit.nil?

        approved = approved_amount(provider, state)
        return nil if approved + operation.amount <= limit

        Violation.new(
          reason: REASON,
          details: limit_details(approved, operation.amount, limit)
        )
      end

      def self.approved_amount(provider, state)
        if state.respond_to?(:daily_approved_amount)
          return state.daily_approved_amount(provider.name)
        end

        provider.daily_approved_amount.to_i
      end
      private_class_method :approved_amount

      def self.limit_details(approved, amount, limit)
        Details.sum_over('daily_approved_amount', approved, amount, 'daily_amount_limit', limit)
      end
      private_class_method :limit_details
    end
  end
end
