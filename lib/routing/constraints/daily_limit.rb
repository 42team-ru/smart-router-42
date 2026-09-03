# frozen_string_literal: true

require_relative 'base'
require_relative '../violation'
require_relative '../details'

module Routing
  module Constraints
    # R-4: дневной лимит одобренной суммы. Равенство лимиту допустимо.
    class DailyLimit < Base
      REASON = 'daily_limit_exceeded'

      def self.violation(provider, operation, _state)
        limit = provider.daily_amount_limit
        return nil if limit.nil?

        approved = provider.daily_approved_amount || 0
        return nil if approved + operation.amount <= limit

        Violation.new(
          reason: REASON,
          details: Details.sum_over(
            'daily_approved_amount', approved, operation.amount, 'daily_amount_limit', limit
          )
        )
      end
    end
  end
end
