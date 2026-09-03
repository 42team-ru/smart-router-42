# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-2: провайдер с нулевой (или неизвестной) долей трафика в каскад не
    # попадает. Единственное исключение — fallback-провайдер spacepayments:
    # валидатор организаторов (строка 31) считает его допустимым всегда,
    # независимо от traffic_percentage.
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
