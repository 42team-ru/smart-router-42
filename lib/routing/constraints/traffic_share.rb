# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера, которому не выделено трафика.
    #
    # Нулевая доля — это способ выключить провайдера, не меняя его статус:
    # он настроен, лимиты живые, но заявки ему сейчас не идут. Неизвестная
    # доля (nil) приравнивается к нулю по тому же принципу, что и в проверке
    # статуса: неизвестность не даёт допуска.
    #
    # Исключение одно — fallback-провайдер (spacepayments). У него доля ноль
    # по смыслу: он не участвует в распределении и существует ровно для тех
    # заявок, которые не взял никто. Отсеки его здесь — и заявка, для которой
    # не нашлось внешнего провайдера, осталась бы вообще без исполнителя.
    # Эталонный допуск организаторов делает то же исключение, так что расхождения
    # с их проверкой здесь нет.
    #
    # Дальше по коду: Execution::Executor#run_fallback — что происходит, когда
    # каскад пуст и заявку принимает fallback.
    class TrafficShare < Base
      REASON = 'zero_traffic_share'
      FALLBACK_PROVIDER = 'spacepayments'

      def self.violation(provider, _operation, _state)
        return nil if provider.name == FALLBACK_PROVIDER

        traffic = provider.traffic_percentage
        return nil unless traffic.nil? || traffic.zero?

        Violation.new(reason: REASON, details: Details.zero_traffic(traffic.nil? ? 0 : traffic))
      end
    end
  end
end
