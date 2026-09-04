# frozen_string_literal: true

require_relative '../routing/constraints'
require_relative 'simulation'

module Offline
  Bound = Data.define(:metrics, :assignment, :passes, :simulations)

  class Oracle
    MAX_PASSES = 3
    LOCAL_SEARCH_MAX_OPS = 500

    def initialize(providers:, operations:, outcomes:, fallback_provider: 'spacepayments',
                   online_metrics: nil)
      @providers = providers
      @operations = operations
      @outcomes = outcomes
      @fallback_provider = fallback_provider
      @online_metrics = online_metrics
      @simulation = Simulation.new(providers: providers, outcomes: outcomes,
                                   fallback_provider: fallback_provider)
    end

    # rubocop:disable-next Metrics/MethodLength
    def call(online_assignment)
      validate_assignment!(online_assignment)
      current, simulations = best_seed(online_assignment)
      return Bound.new(current[:metrics], current[:assignment], 0, simulations) if too_large?

      passes = 0
      MAX_PASSES.times do
        improved = improve_once(current)
        break unless improved

        current = improved
        passes += 1
      end
      Bound.new(current[:metrics], current[:assignment], passes, @simulations)
    end

    def self.online_assignment(pairs, fallback_provider: 'spacepayments')
      pairs.map do |_operation, outcome|
        attempt = outcome.attempts.find { |item| item.decision == 'selected' }
        provider_name = attempt&.provider&.then do |provider|
          provider.respond_to?(:name) ? provider.name : provider
        end
        provider_name == fallback_provider ? nil : provider_name
      end
    end

    private

    def best_seed(online_assignment)
      @simulations = 0
      seeds = [evaluate(online_assignment), evaluate(greedy_assignment),
               evaluate(Array.new(@operations.size))]
      seeds << { assignment: online_assignment, metrics: @online_metrics } if @online_metrics
      [seeds.min_by { |candidate| candidate[:metrics].key }, @simulations]
    end

    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def greedy_assignment
      counts = @providers.to_h { |provider| [provider.name, 0] }
      @operations.each_with_index.map do |operation, index|
        candidates = eligible_original(operation)
        selected = candidates.min_by do |provider|
          next_counts = counts.merge(provider.name => counts.fetch(provider.name) + 1)
          # Это только чистая эвристическая оценка первого кандидата; итог всегда
          # пересимулируется целиком, поэтому attempt_no здесь сознательно равен 1.
          rejected = @outcomes.call(operation, provider, 1) == :rejected ? 1 : 0
          # Префикс условно считает все прошлые операции доставленными: это лишь
          # tie-break жадного засева, не метрика финального назначения.
          metrics = Objective.metrics(counts: next_counts, delivered: index + 1,
                                      providers: @providers, total: @operations.size)
          [rejected, metrics.max_deviation_num,
           provider.name]
        end
        counts[selected.name] += 1 if selected
        selected&.name
      end
    end

    # rubocop:disable-next Metrics/AbcSize
    def improve_once(current)
      @operations.each_with_index do |operation, index|
        alternatives = eligible_original(operation).map(&:name).sort - [current[:assignment][index]]
        alternatives.each do |provider_name|
          assignment = current[:assignment].dup
          assignment[index] = provider_name
          candidate = evaluate(assignment)
          return candidate if (candidate[:metrics].key <=> current[:metrics].key) == -1
        end
      end
      nil
    end

    def evaluate(assignment)
      @simulations += 1
      { assignment: assignment, metrics: @simulation.run(@operations, assignment) }
    end

    def eligible_original(operation)
      @providers.reject { |provider| provider.name == @fallback_provider }
                .select { |provider| Routing::Constraints.eligible?(provider, operation) }
                .sort_by(&:name)
    end

    def too_large?
      @operations.size > LOCAL_SEARCH_MAX_OPS
    end

    def validate_assignment!(assignment)
      return if assignment.size == @operations.size

      raise ArgumentError, 'online assignment size must equal operations size'
    end
  end
end
