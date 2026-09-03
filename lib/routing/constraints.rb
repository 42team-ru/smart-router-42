# frozen_string_literal: true

require_relative 'reasons'
require_relative 'constraints/base'
require_relative 'constraints/status'
require_relative 'constraints/traffic_share'
require_relative 'constraints/amount_range'
require_relative 'constraints/daily_limit'
require_relative 'constraints/in_progress'
require_relative 'constraints/bank_filter'
require_relative 'constraints/margin'
require_relative 'constraints/requisites'
require_relative 'constraints/rate_limit'

module Routing
  module Constraints
    # Причины отсева, которые вправе возвращать hard-constraints.
    REASONS = Reasons::SKIP

    REGISTRY = [Status, TrafficShare, AmountRange, DailyLimit,
                InProgress, BankFilter, Margin, Requisites, RateLimit].freeze

    def self.check(provider, operation, state = nil)
      REGISTRY.lazy.filter_map do |constraint|
        constraint.violation(provider, operation, state)
      end.first
    end

    def self.eligible?(provider, operation, state = nil)
      check(provider, operation, state).nil?
    end
  end
end
