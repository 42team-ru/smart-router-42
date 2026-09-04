# frozen_string_literal: true

module Routing
  # План маршрута одной операции: упорядоченный каскад и отсеянные с причинами.
  # Строится ДО первой попытки и после отказа не пересчитывается.
  #   candidates — Array<Domain::Provider>, порядок = порядок каскада, без дублей
  #   skipped    — Array<[Domain::Provider, Routing::Violation]>
  class RoutePlan
    attr_reader :operation, :candidates, :skipped, :trace

    def initialize(operation:, candidates:, skipped:, trace: nil)
      validate_no_duplicates!(candidates)
      validate_no_overlap!(candidates, skipped)

      @operation = operation
      @candidates = candidates
      @skipped = skipped
      @trace = trace
      freeze
    end

    # 1-based позиция провайдера в каскаде, nil если провайдера в каскаде нет.
    def attempt_no_for(provider)
      index = candidates.map(&:name).index(provider.name)
      index.nil? ? nil : index + 1
    end

    # true, если ни один провайдер не допущен — сигнал для fallback по допуску.
    def empty?
      candidates.empty?
    end

    private

    def validate_no_duplicates!(candidates)
      names = candidates.map(&:name)
      return if names.uniq.length == names.length

      raise ArgumentError, 'candidates contains duplicate providers by name'
    end

    def validate_no_overlap!(candidates, skipped)
      overlap = candidates.map(&:name) & skipped.map { |provider, _violation| provider.name }
      return if overlap.empty?

      raise ArgumentError, "candidates and skipped overlap: #{overlap.join(', ')}"
    end
  end
end
