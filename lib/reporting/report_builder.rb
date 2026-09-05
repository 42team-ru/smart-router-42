# frozen_string_literal: true

require 'json'
require_relative '../routing/reasons'
require_relative '../routing/achievable'
require_relative '../routing/constraints'
require_relative '../offline/objective'
require_relative 'deviation_causes'
require_relative 'distributions'
require_relative 'recommendations'
require_relative 'retarget'
require_relative 'utilization'

module Reporting
  # Сборка routing_report.json из уже готовых решений.
  #
  # Вход — те же пары (Domain::Operation, Execution::Outcome), что и у
  # DecisionsWriter, плюс снимок провайдеров (цели, лимиты, паспортные
  # конверсии) и калибровка Io::HistoryLoader (наблюдаемые конверсии).
  #
  # achievable_pct считается по-настоящему: Routing::Achievable.for_queue на
  # множестве допустимых по ИСХОДНОМУ снапшоту. Это офлайн-расчёт, он идёт
  # только в отчёт и никогда в принятие решений. Тот же achievable/eligibility
  # переиспользуют DeviationCauses и Retarget -- считается один раз в #sections,
  # а не заново в каждой секции.
  #
  # benchmark остаётся заглушкой только как дефолт на случай отсутствия
  # kwarg-а (см. #benchmark ниже) -- в реальном прогоне bin/route всегда
  # передаёт настоящий эталон (lib/offline/*).
  # rubocop:disable-next Metrics/ModuleLength -- отчёт собран в одном публичном фасаде.
  module ReportBuilder
    FALLBACK_PROVIDER = 'spacepayments'

    # comparison: секция приходит готовым хешем из Offline::Comparison.build,
    # как benchmark -- внутри build ничего
    # не гоняет. nil (дефолт) -- ключа `comparison` в отчёте нет вовсе, не
    # null-заглушка: старые вызовы без этого kwarg-а получают отчёт прежней формы.
    # rubocop:disable-next Metrics/ParameterLists -- параметры отражают секции неизменяемого отчёта.
    def self.build(pairs, providers:, history: {}, strategy: nil, benchmark: nil, comparison: nil)
      operations = pairs.map(&:first)
      outcomes = pairs.map(&:last)

      report = header(operations, strategy)
               .merge(sections(pairs, outcomes, providers, history, benchmark))
      comparison.nil? ? report : report.merge('comparison' => comparison)
    end

    # rubocop:disable-next Metrics/ParameterLists -- параметры отражают секции неизменяемого отчёта.
    def self.write(path, pairs, providers:, history: {}, strategy: nil, benchmark: nil,
                   comparison: nil)
      report = build(pairs, providers: providers, history: history, strategy: strategy,
                            benchmark: benchmark, comparison: comparison)
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

    def self.sections(pairs, outcomes, providers, history, benchmark)
      operations = pairs.map(&:first)
      eligibility = eligibility_for(operations, providers)
      achievable = Routing::Achievable.for_queue(operations: operations, providers: providers,
                                                 eligibility: eligibility)
      metrics = Offline::Objective.from_pairs(pairs, providers: providers)

      distributions(pairs, outcomes, providers, achievable)
        .merge(analytics(pairs, outcomes, providers, history, benchmark, achievable, eligibility,
                         metrics))
    end
    private_class_method :sections

    def self.distributions(pairs, outcomes, providers, achievable)
      {
        'distribution' => Distributions.by_final(pairs, providers, :count, achievable),
        'volume_distribution' => Distributions.by_final(pairs, providers, :amount, achievable),
        'attempt_distribution' => Distributions.by_attempt(outcomes, providers)
      }
    end
    private_class_method :distributions

    # Допуск считается по исходному снапшоту, без state: списания лимитов пул
    # только сужают, а достижимость -- это потолок «как могло бы быть».
    # spacepayments в множество не входит: он fallback по допуску, и включение
    # его в eligibility сломало бы нижние границы Achievable (операция с
    # единственным внешним провайдером перестала бы такой считаться).
    def self.eligibility_for(operations, providers)
      external = providers.reject { |provider| provider.name == FALLBACK_PROVIDER }
      operations.to_h do |operation|
        names = external.select { |provider| Routing::Constraints.eligible?(provider, operation) }
        [operation.operation_id, names.map(&:name)]
      end
    end
    private_class_method :eligibility_for

    # rubocop:disable-next Metrics/ParameterLists -- параметры отражают уже посчитанные секции отчёта.
    def self.analytics(pairs, outcomes, providers, history, benchmark, achievable, eligibility,
                       metrics)
      {
        'skip_reasons' => Distributions.skip_reasons(outcomes),
        'projected_daily_utilization' => Utilization.projected_daily(pairs, providers),
        'fallback' => fallback(outcomes),
        'benchmark' => benchmark || self.benchmark,
        'deviation_causes' => DeviationCauses.build(pairs, providers, achievable, eligibility),
        'recommendations' => build_recommendations(pairs, providers, history, achievable, metrics)
      }
    end
    private_class_method :analytics

    def self.build_recommendations(pairs, providers, history, achievable, metrics)
      recommendations = Recommendations.build(pairs, providers, history)
      retarget = Retarget.build(providers, achievable, metrics)

      retarget ? recommendations + [retarget] : recommendations
    end
    private_class_method :build_recommendations

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
    # исчерпан (итог не approved, но selected остаётся последним реальным
    # кандидатом, а не spacepayments).
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
        'offline_bound' => nil,
        'our_online_result' => nil,
        'competitive_ratio' => nil,
        'note' => 'эталон не считался'
      }
    end
    private_class_method :benchmark
  end
end
