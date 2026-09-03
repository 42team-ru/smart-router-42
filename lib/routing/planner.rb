# frozen_string_literal: true

require_relative 'constraints'
require_relative 'route_plan'
require_relative 'strategies'
require_relative 'strategies/count_share'
require_relative 'share_ledger'

module Routing
  # Строит каскад одной операции из её текущего снимка провайдеров.
  class Planner
    attr_reader :strategy

    def initialize(providers:, fallback_provider: 'spacepayments',
                   strategy: Strategies.build('count_share'))
      @providers = providers
      @fallback_provider = fallback_provider
      @strategy = strategy
    end

    def plan(operation, state = nil)
      candidates, skipped = external_providers.partition do |provider|
        Constraints.eligible?(provider, operation, state)
      end
      skipped = skipped.map do |provider|
        [provider, Constraints.check(provider, operation, state)]
      end

      ranked = strategy.rank(candidates, operation, state || ShareLedger.new)
      validate_permutation!(candidates, ranked)
      RoutePlan.new(operation: operation, candidates: ranked, skipped: skipped)
    end

    def fallback_provider_object
      providers.find { |provider| provider.name == fallback_provider }
    end

    private

    attr_reader :providers, :fallback_provider

    def external_providers
      providers.reject { |provider| provider.name == fallback_provider }
    end

    def validate_permutation!(candidates, ranked)
      same_size = ranked.size == candidates.size
      same_names = ranked.map(&:name).sort == candidates.map(&:name).sort
      valid = same_size && same_names
      return if valid

      raise "strategy #{strategy.name} returned a non-permutation"
    end
  end
end
