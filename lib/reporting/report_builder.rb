# frozen_string_literal: true

require 'json'
require_relative '../routing/reasons'
require_relative 'distributions'
require_relative 'recommendations'
require_relative 'utilization'

module Reporting
  # A-3..A-6: сборка routing_report.json из уже готовых решений.
  #
  # Вход — те же пары (Domain::Operation, Execution::Outcome), что и у
  # DecisionsWriter, плюс снимок провайдеров (цели, лимиты, паспортные
  # конверсии) и калибровка Io::HistoryLoader (наблюдаемые конверсии).
  #
  # achievable_pct/benchmark/deviation_causes — заглушки (docs/TASKS.md,
  # «Правила ведения»: формат отчёта после гейта Ф2 не меняется, поэтому эти
  # поля заводятся в структуре сразу, с настоящей логикой позже).
  module ReportBuilder
    def self.build(pairs, providers:, history: {}, strategy: nil)
      operations = pairs.map(&:first)
      outcomes = pairs.map(&:last)

      header(operations, strategy).merge(sections(pairs, outcomes, providers, history))
    end

    def self.write(path, pairs, providers:, history: {}, strategy: nil)
      report = build(pairs, providers: providers, history: history, strategy: strategy)
      File.write(path, "#{JSON.pretty_generate(report)}\n")
    end

    def self.header(operations, strategy)
      {
        'period' => period(operations),
        'total_operations' => operations.size,
        'strategy' => strategy
      }
    end
    private_class_method :header

    def self.sections(pairs, outcomes, providers, history)
      distributions(pairs, outcomes, providers)
        .merge(analytics(pairs, outcomes, providers, history))
    end
    private_class_method :sections

    def self.distributions(pairs, outcomes, providers)
      {
        'distribution' => Distributions.by_final(pairs, providers, :count),
        'volume_distribution' => Distributions.by_final(pairs, providers, :amount),
        'attempt_distribution' => Distributions.by_attempt(outcomes, providers)
      }
    end
    private_class_method :distributions

    def self.analytics(pairs, outcomes, providers, history)
      {
        'skip_reasons' => Distributions.skip_reasons(outcomes),
        'projected_daily_utilization' => Utilization.projected_daily(pairs, providers),
        'fallback' => fallback(outcomes),
        'benchmark' => benchmark,
        'deviation_causes' => [],
        'recommendations' => Recommendations.build(pairs, providers, history)
      }
    end
    private_class_method :analytics

    def self.period(operations)
      return nil if operations.empty?

      operations.first.created_at[0, 10]
    end
    private_class_method :period

    def self.fallback(outcomes)
      stats = outcomes.map { |outcome| fallback_stat(outcome) }

      {
        'first_attempt_success' => stats.count { |stat| stat == :first_attempt },
        'recovered_by_fallback' => stats.count { |stat| stat == :recovered },
        'fallback_rate_pct' => fallback_rate_pct(stats),
        'spacepayments_used' => spacepayments_used(outcomes),
        'cascade_exhausted' => stats.count { |stat| stat == :exhausted }
      }
    end
    private_class_method :fallback

    # Классифицирует одну заявку: первая реальная попытка approved,
    # восстановлена каскадом (>1 реальной попытки, approved), либо каскад
    # исчерпан (правило E-4: итог не approved, но selected остаётся
    # последним реальным кандидатом, а не spacepayments).
    def self.fallback_stat(outcome)
      return :exhausted unless outcome.result == :approved

      real_attempt_count(outcome) > 1 ? :recovered : :first_attempt
    end
    private_class_method :fallback_stat

    def self.real_attempt_count(outcome)
      outcome.attempts.count { |attempt| attempt.decision == 'selected' }
    end
    private_class_method :real_attempt_count

    def self.fallback_rate_pct(stats)
      return 0.0 if stats.empty?

      (stats.count { |stat| stat == :recovered }.to_f / stats.size * 100).round(1)
    end
    private_class_method :fallback_rate_pct

    # spacepayments появляется только когда допустимых кандидатов не было
    # вовсе (reason == fallback_no_eligible_provider), не как исход каскада.
    def self.spacepayments_used(outcomes)
      outcomes.count do |outcome|
        outcome.attempts.any? do |attempt|
          attempt.decision == 'selected' && attempt.reason == Routing::Reasons::SELECTED.fetch(4)
        end
      end
    end
    private_class_method :spacepayments_used

    def self.benchmark
      {
        'offline_optimum_deviation_pp' => nil,
        'ours_deviation_pp' => nil,
        'competitive_ratio' => nil
      }
    end
    private_class_method :benchmark
  end
end
