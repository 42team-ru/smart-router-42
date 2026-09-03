# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-1: провайдер обязан быть в статусе "active". nil в status тоже считается
    # неактивным — данных о допуске нет.
    class Status < Base
      REASON = 'provider_inactive'

      def self.violation(provider, _operation, _state)
        return nil if provider.status == 'active'

        status_label = provider.status.nil? ? 'nil' : provider.status
        Violation.new(reason: REASON, details: Details.inactive(status_label))
      end
    end
  end
end
