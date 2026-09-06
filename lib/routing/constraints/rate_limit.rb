# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, у которого исчерпан лимит запросов в минуту.
    # Считаются отправленные запросы, а не успешные выплаты.
    #
    # Минута берётся из created_at заявки, а не из системных часов: обращение
    # к текущему времени в решающем пути ломает воспроизводимость и ловится
    # scripts/check_determinism.sh.
    #
    # Нет лимита или нет состояния со счётчиком — отсева не происходит.
    #
    # Единственная проверка вне общего реестра: в Planner она применяется
    # смягчённо, не опустошая пул кандидатов. В реестре она ужесточила бы и
    # офлайн-расчёты, где смягчения нет.
    class RateLimit < Base
      REASON = 'rate_limit_exceeded'

      def self.violation(provider, operation, state)
        limit = provider.requests_per_minute_limit
        return nil if limit.nil?

        count = request_count(state, provider.name, minute_key(operation))
        return nil if count.nil?
        return nil unless exceeds_limit?(count, limit)

        violation_for(count, limit)
      end

      def self.minute_key(operation)
        operation.created_at[0, 16]
      end

      def self.violation_for(count, limit)
        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'запросов за минуту', count, 1, 'requests_per_minute_limit', limit
          )
        )
      end

      def self.request_count(state, provider_name, minute)
        return nil if state.nil? || !state.respond_to?(:requests_in_minute)

        state.requests_in_minute(provider_name, minute)
      end

      def self.exceeds_limit?(count, limit)
        count + 1 > limit
      end
      private_class_method :violation_for, :request_count, :exceeds_limit?
    end
  end
end
