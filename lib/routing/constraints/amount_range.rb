# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-3: границы суммы операции. nil в каждой отдельной границе означает,
    # что соответствующего ограничения нет.
    class AmountRange < Base
      MIN_REASON = 'amount_below_minimum'
      MAX_REASON = 'amount_exceeds_limit'

      def self.violation(provider, operation, _state)
        min = provider.limit_amount_min
        if !min.nil? && operation.amount < min
          return Violation.new(
            reason: MIN_REASON,
            details: Details.below_min(operation.amount, min)
          )
        end

        max = provider.limit_amount_max
        return nil if max.nil? || operation.amount <= max

        Violation.new(reason: MAX_REASON, details: Details.above_max(operation.amount, max))
      end
    end
  end
end
