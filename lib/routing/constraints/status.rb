# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # Отсекает провайдера со статусом, отличным от "active". Первая и самая
    # дешёвая проверка допуска.
    #
    # nil означает «статус неизвестен» и тоже отсеивает: неизвестность
    # трактуется не в пользу провайдера.
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
