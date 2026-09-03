# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-8: провайдеру нечем принять операцию, если свободных реквизитов нет.
    # nil трактуется как «данных нет, провайдер не годен», отрицательное
    # значение — тоже отсев.
    class Requisites < Base
      REASON = 'no_requisites'

      def self.violation(provider, _operation, _state)
        requisites = provider.available_requisites
        return nil if requisites&.positive?

        Violation.new(reason: REASON,
                      details: Details.no_requisites(requisites.nil? ? 0 : requisites))
      end
    end
  end
end
