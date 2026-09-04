# frozen_string_literal: true

require_relative '../execution/executor'
require_relative '../routing/constraints'
require_relative '../routing/route_plan'
require_relative '../state/providers'
require_relative 'objective'

module Offline
  class Simulation
    def initialize(providers:, outcomes:, fallback_provider: 'spacepayments')
      @providers = providers
      @outcomes = outcomes
      @fallback_provider = fallback_provider
    end

    # rubocop:disable-next Metrics/MethodLength
    def run(operations, assignment)
      unless assignment.size == operations.size
        raise ArgumentError,
              'assignment size must equal operations size'
      end

      state = State::Providers.new(@providers)
      executor = Execution::Executor.new(outcomes: @outcomes)
      pairs = operations.each_with_index.map do |operation, index|
        plan = plan_for(operation, assignment[index], state)
        [operation, executor.run(plan, operation, state)]
      end
      Objective.from_pairs(pairs, providers: @providers)
    end

    private

    def plan_for(operation, assigned_name, state)
      live = @providers.reject { |provider| provider.name == @fallback_provider }
                       .select { |provider| Routing::Constraints.eligible?(provider, operation, state) }
      first = live.find { |provider| provider.name == assigned_name }
      rest = live.reject { |provider| provider == first }.sort_by(&:name)
      Routing::RoutePlan.new(operation: operation, candidates: [first, *rest].compact,
                             skipped: [], trace: nil)
    end
  end
end
