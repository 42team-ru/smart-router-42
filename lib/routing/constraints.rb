# frozen_string_literal: true

require_relative 'reasons'
require_relative 'constraints/base'

module Routing
  module Constraints
    # Причины отсева, которые вправе возвращать hard-constraints.
    REASONS = Reasons::SKIP

    # REGISTRY появляется в задаче R-10.
    # Девять классов в фиксированном порядке допуска:
    #   Status, TrafficShare, AmountRange, DailyLimit, InProgress,
    #   BankFilter, Margin, Requisites, RateLimit
    # Пустой реестр в этом пакете не заводим: он молча пропустил бы всех.
  end
end
