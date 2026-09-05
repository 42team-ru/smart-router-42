# frozen_string_literal: true

module Synthetic
  # Накопитель ожидаемого выхода. Заполняется в ТОМ ЖЕ проходе, что и очередь
  # (Queue#each_with_expectation) — не отдельным пересчётом.
  #
  # exact — точечные проверки 1:1 (см. queue.rb: только якоря, у которых
  # единственный допустимый провайдер гарантирован конструкцией входа).
  # Ограничен exact_cap: у нас якорей O(providers), не O(operations), поэтому
  # предел почти никогда не достигается — это просто страховка на случай
  # уровня с необычно большим числом провайдеров.
  #
  # tolerances — коридоры по агрегатам, а не по отдельным решениям: они верны
  # для ЛЮБОЙ стратегии/слоя ровно потому, что не предполагают конкретного
  # алгоритма ранжирования, только статические свойства входа.
  class Expectation
    attr_reader :meta, :exact, :counts, :tolerances

    def initialize(meta:, exact_cap:)
      @meta = meta
      @exact_cap = exact_cap
      @exact = {}
      @counts = Hash.new(0)
      @tolerances = {}
    end

    def add_exact(operation_id, provider:, reason:)
      return if @exact.size >= @exact_cap

      @exact[operation_id] = { 'provider' => provider, 'reason' => reason }
    end

    def increment(key) = @counts[key] += 1

    def increment_by(key, delta) = @counts[key] += delta

    def record_tolerance(key, range) = @tolerances[key] = range

    def record_distribution_tolerance(distribution) = @tolerances['distribution_pp'] = distribution

    def to_h
      {
        'meta' => meta,
        'exact' => exact,
        'exact_checked' => exact.size,
        'counts' => counts,
        'tolerances' => tolerances
      }
    end
  end
end
