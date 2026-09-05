# frozen_string_literal: true

require_relative '../routing/constraints'

module Bench
  # Сверяет факт с expectation.json (Synthetic::Expectation#to_h) в двух
  # режимах:
  #
  #   #observe(operation, outcome) — O(1) на операцию, вызывается из того же
  #     цикла, что и Accumulator#add. Проверяет точные якоря (exact) и
  #     универсальный инвариант "selected_provider допустим по исходному
  #     снапшоту" — единственная проверка, которая не зависит от
  #     того, что именно сгенерировал Synthetic::Queue.
  #
  #   #finish(accumulator) — один раз в конце прохода, сверяет агрегаты
  #     (counts/tolerances) с итоговыми счётчиками Bench::Accumulator.
  #
  # При провале печатает конкретику (operation_id, ожидание, факт, причину
  # отсева лишних кандидатов), а не "expectation mismatch" — иначе бенчмарк
  # находит расхождение, но не говорит, что чинить.
  class Comparator
    Report = Data.define(:ok, :exact_checked, :exact_failed, :hard_violations, :failures,
                         :aggregate_failures)

    MAX_DETAILS = 20

    def initialize(expectation, providers:, fallback_name: 'spacepayments')
      @exact = expectation.fetch('exact')
      @counts = expectation.fetch('counts')
      @tolerances = expectation.fetch('tolerances')
      @providers_by_name = providers.to_h { |provider| [provider.name, provider] }
      @fallback_name = fallback_name
      @exact_checked = 0
      @exact_failed = 0
      @hard_violations = 0
      @failures = []
    end

    def observe(operation, outcome)
      check_exact(operation, outcome)
      check_hard_constraint(operation, outcome)
    end

    def finish(accumulator)
      aggregate_failures = []
      check_exact_count(accumulator, aggregate_failures)
      check_queue_errors(accumulator, aggregate_failures)
      check_tolerance_range(@tolerances['delivered'], accumulator.delivered, 'delivered',
                            aggregate_failures)
      check_distribution(accumulator, aggregate_failures)

      ok = @exact_failed.zero? && @hard_violations.zero? && aggregate_failures.empty?
      Report.new(ok: ok, exact_checked: @exact_checked, exact_failed: @exact_failed,
                 hard_violations: @hard_violations, failures: @failures,
                 aggregate_failures: aggregate_failures)
    end

    private

    def check_exact(operation, outcome)
      expected = @exact[operation.operation_id]
      return unless expected

      @exact_checked += 1
      actual = outcome.selected.name
      return if actual == expected['provider']

      @exact_failed += 1
      record_exact_failure(operation, expected, actual)
    end

    def record_exact_failure(operation, expected, actual)
      return if @failures.size >= MAX_DETAILS

      eligible = eligible_names(operation)
      @failures << "#{operation.operation_id}: ожидали #{expected['provider']} " \
                   "(#{expected['reason']}), получили #{actual}; допустимые по снапшоту: " \
                   "#{eligible.empty? ? 'нет' : eligible.join(', ')}"
    end

    def eligible_names(operation)
      @providers_by_name.values.reject { |provider| provider.name == @fallback_name }
                        .select { |provider| Routing::Constraints.eligible?(provider, operation) }
                        .map(&:name)
    end

    # Инвариант: "selected_provider обязан входить в множество допустимых по
    # исходному снапшоту" — единственный инвариант, который верен независимо
    # от профиля/уровня/стратегии. spacepayments исключён: он fallback по
    # допуску, а не элемент каскада, отдельного условия допустимости для него
    # нет (TrafficShare прямо делает для него исключение).
    def check_hard_constraint(operation, outcome)
      name = outcome.selected.name
      return if name == @fallback_name

      provider = @providers_by_name.fetch(name)
      return if Routing::Constraints.eligible?(provider, operation)

      @hard_violations += 1
      return if @failures.size >= MAX_DETAILS

      violation = Routing::Constraints.check(provider, operation)
      @failures << "#{operation.operation_id}: выбран #{name}, но он недопустим по снапшоту " \
                   "(#{violation.reason}: #{violation.details})"
    end

    def check_exact_count(accumulator, failures)
      expected = @counts['spacepayments_used']
      return if expected.nil?

      actual = accumulator.fallback['spacepayments_used']
      return if actual == expected

      failures << "spacepayments_used: ожидали #{expected}, получили #{actual}"
    end

    def check_queue_errors(accumulator, failures)
      expected = @counts['queue_errors']
      return if expected.nil?

      return if accumulator.queue_errors == expected

      failures << "queue_errors: ожидали #{expected}, получили #{accumulator.queue_errors}"
    end

    def check_tolerance_range(range, actual, label, failures)
      return if range.nil?

      low, high = range
      return if actual.between?(low, high)

      failures << "#{label}: #{actual} вне коридора [#{low}, #{high}]"
    end

    def check_distribution(accumulator, failures)
      dist = @tolerances['distribution_pp']
      return if dist.nil?

      actual = accumulator.distribution
      dist.each do |name, range|
        share = actual.dig(name, 'share_pct') || 0.0
        check_tolerance_range(range, share, "distribution_pp.#{name}", failures)
      end
    end
  end
end
