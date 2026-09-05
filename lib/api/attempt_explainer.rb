# frozen_string_literal: true

require_relative '../routing/attempt'

module Api
  # Пост-обработка Outcome: нормализует Attempt#provider из Domain::Provider
  # в строку-имя (JSON-контракт), и объясняет первую реальную попытку в
  # терминах стратегии (best_target_adherence + explain).
  #
  # Логика повторяет bin/route#explain_first_attempt: нельзя тронуть ни CLI,
  # ни lib/routing, поэтому это отдельный namespace для сервиса.
  module AttemptExplainer
    def self.call(outcome, plan, operation, strategy, ledger)
      attempts = outcome.attempts.map do |attempt|
        rebuild_attempt(attempt, plan, operation, strategy, ledger)
      end
      outcome.with(attempts: attempts)
    end

    def self.rebuild_attempt(attempt, plan, operation, strategy, ledger)
      provider_name = provider_name_of(attempt)
      return attempt.with(provider: provider_name) unless first_selected?(attempt, plan)

      details = details_for(plan, operation, strategy, ledger)
      attrs = { provider: provider_name, details: details, strategy: plan.trace.strategy_name }
      attrs[:reason] = 'best_target_adherence' if first_ranked?(attempt, plan)
      attempt.with(**attrs)
    end

    def self.provider_name_of(attempt)
      attempt.provider.respond_to?(:name) ? attempt.provider.name : attempt.provider
    end

    def self.first_selected?(attempt, plan)
      attempt.decision == 'selected' && attempt.attempt_no == 1 && !plan.trace.nil?
    end

    def self.first_ranked?(attempt, plan)
      attempt.decision == 'selected' && attempt.attempt_no == 1 && plan.candidates.size > 1
    end

    def self.details_for(plan, operation, strategy, ledger)
      return plan.trace.details unless plan.trace.segments.one?

      strategy.explain(plan.candidates, operation, ledger)
    end
  end
end
