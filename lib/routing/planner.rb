# frozen_string_literal: true

require_relative 'constraints'
require_relative 'route_plan'

module Routing
  # Строит каскад одной операции из её текущего снимка провайдеров.
  class Planner
    def initialize(providers:, fallback_provider: 'spacepayments')
      @providers = providers
      @fallback_provider = fallback_provider
    end

    def plan(operation, state = nil)
      candidates, skipped = external_providers.partition do |provider|
        Constraints.eligible?(provider, operation, state)
      end
      skipped = skipped.map do |provider|
        [provider, Constraints.check(provider, operation, state)]
      end

      # Ф2/S-1: порядок каскада заменит стратегия CountShare.
      candidates.sort_by! { |provider| [provider.priority, provider.name] }
      RoutePlan.new(operation: operation, candidates: candidates, skipped: skipped)
    end

    def fallback_provider_object
      providers.find { |provider| provider.name == fallback_provider }
    end

    private

    attr_reader :providers, :fallback_provider

    def external_providers
      providers.reject { |provider| provider.name == fallback_provider }
    end
  end
end
