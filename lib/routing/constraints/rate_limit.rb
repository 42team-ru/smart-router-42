# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, в которого мы упёрлись по частоте обращений.
    #
    # У провайдера есть предел «не больше N запросов в минуту» — превышение
    # ведёт к отказам на его стороне или к бану. Считаются именно отправленные
    # запросы, а не успешные выплаты: провайдеру одинаково дорого обрабатывать
    # и одобренную заявку, и отклонённую.
    #
    # Минута берётся из поля created_at самой заявки, а не из системных часов.
    # Это обязательное условие воспроизводимости: прогон вчера и прогон сегодня
    # обязаны дать один результат. Обращение к текущему времени в решающем пути
    # запрещено и ловится статической проверкой (scripts/check_determinism.sh).
    #
    # Проверка молчит, если нечего проверять: нет лимита у провайдера или нет
    # состояния со счётчиком — отсева не происходит. Ограничение, параметра
    # которого нет, не должно отсеивать никого.
    #
    # Единственная проверка допуска вне общего реестра. Причина — в Planner:
    # эталонный допуск организаторов про интенсивность не знает, поэтому у нас
    # она применяется смягчённо (не опустошая пул кандидатов), и это смягчение
    # живёт только на пути реального роутинга. Останься проверка в общем
    # реестре — она ужесточила бы расчёты допустимого молча и без смягчения.
    #
    # Дальше по коду: Routing::Planner#apply_rate_limit — само правило и его
    # объяснение в plan trace; State::Providers#requests_in_minute — счётчик,
    # который растёт при резерве и не уменьшается при откате;
    # docs/QUESTIONS_FOR_EXPERTS.md, В-1 — открытый вопрос организаторам
    # о том, верна ли такая трактовка.
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
