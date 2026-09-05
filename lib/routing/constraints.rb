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

    # П2 (docs/plans/P6/P2_rate_limit.md): RateLimit сюда намеренно не входит.
    # Constraints.check/eligible? используются не только Planner'ом (который
    # реализует смягчение Ф-4), но и Routing::Achievable, ReportBuilder, а также
    # офлайн-расчётами вне lib/routing и lib/execution -- там requests_in_minute
    # либо не применяется вовсе, либо применялся бы БЕЗ смягчения "не опустошай
    # пул". Держать RateLimit в общем REGISTRY значило бы тихо ужесточить допуск
    # в этих местах мимо решения Ф-4. Отдельный этап живёт только в Planner#plan,
    # который дергает Constraints::RateLimit напрямую.
    REGISTRY = [Status, TrafficShare, AmountRange, DailyLimit,
                InProgress, BankFilter, Margin, Requisites].freeze

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
