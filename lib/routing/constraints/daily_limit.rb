# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, которому эта заявка не влезает в дневной лимит.
    #
    # Считает не «сколько уже потрачено», а «сколько станет, если отдать эту
    # заявку»: сумма одобренного за день плюс текущая сумма против лимита.
    # Равенство лимиту допустимо — заявка, ровно добирающая лимит, проходит.
    #
    # Главное здесь — откуда берётся «уже одобрено». Если передано состояние
    # прогона, цифра берётся из него, а не из снапшота: за время очереди мы
    # сами могли отдать провайдеру несколько заявок, и снапшот об этом не
    # знает. Без такого учёта лимит был бы превышен на живом прогоне, оставаясь
    # формально соблюдённым по исходным данным. Когда состояния нет (одиночная
    # проверка, офлайн-расчёт), берётся значение из снапшота.
    #
    # Это ограничение — причина главной ловушки публичной очереди: у payflow
    # остаётся 100 000 ₽ при четырёх доступных ему заявках на 103 800 ₽, и
    # порядок выдачи решает, достанется ли ему та единственная, которую больше
    # взять некому.
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
