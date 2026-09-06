# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера с нулевой долей трафика: так провайдера выключают,
    # не меняя статус. nil приравнивается к нулю.
    #
    # Исключение — fallback-провайдер: у него доля ноль по смыслу, он берёт
    # заявки, которые не взял никто. Валидатор в reference/ делает то же
    # исключение.
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
