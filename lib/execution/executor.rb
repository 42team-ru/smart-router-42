# frozen_string_literal: true

require 'routing/attempt'
require 'routing/reasons'
require_relative 'outcome'

module Execution
  # Проход по каскаду. Стратегия ранжирует, исполнитель исполняет:
  # Executor не пересчитывает план после отказа и не знает про доли/лимиты.
  #
  #   approved -> commit, каскад закончен
  #   rejected -> rollback, следующий кандидат
  #   expired  -> hold, каскад НЕ продолжается (условно успешен)
  #
  # Каскад исчерпан -> selected_provider последний реальный кандидат,
  # НЕ spacepayments. spacepayments — fallback по допуску (пустой каскад),
  # а не по исходу (§7 ARCH).
  class Executor
    def initialize(outcomes:)
      @outcomes = outcomes
    end

    def run(plan, operation, state)
      attempts = plan.skipped.map { |provider, violation| violation.to_attempt(provider) }
      total_reviewed = plan.candidates.size + plan.skipped.size

      return run_fallback(plan, operation, state, attempts, total_reviewed) if plan.empty?

      run_cascade(plan, operation, state, attempts, total_reviewed)
    end

    private

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- машина состояний
    # каскада — единый цикл с тремя ветвями исхода; фрагментация вредит связности.
    def run_cascade(plan, operation, state, attempts, total_reviewed)
      plan.candidates.each_with_index do |provider, i|
        attempt_no = i + 1
        state.reserve(provider, operation)
        result = @outcomes.call(operation, provider, attempt_no)
        attempts << build_selected_attempt(
          provider: provider, attempt_no: attempt_no, result: result,
          total_candidates: plan.candidates.size, total_reviewed: total_reviewed,
          previous_provider: (attempt_no > 1 ? plan.candidates[i - 1] : nil)
        )

        case result
        when :approved
          state.commit(provider, operation)
          return Outcome.new(selected: provider, attempts: attempts, result: :approved)
        when :expired
          state.hold(provider, operation)
          return Outcome.new(selected: provider, attempts: attempts, result: :expired)
        when :rejected
          state.rollback(provider, operation)
        end
      end

      # Каскад исчерпан — selected становится последний реальный кандидат.
      Outcome.new(selected: plan.candidates.last, attempts: attempts, result: :rejected)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # rubocop:disable Metrics/MethodLength -- одна попытка fallback с полной
    # обвязкой (reserve/call/attempt/state); дробление скроет цельность операции.
    def run_fallback(_plan, operation, state, attempts, total_reviewed)
      fallback = state.fallback
      state.reserve(fallback, operation)
      result = @outcomes.call(operation, fallback, 1)
      attempts << Routing::Attempt.new(
        provider: fallback, decision: 'selected',
        reason: 'fallback_no_eligible_provider',
        details: "допустимых внешних провайдеров 0 из #{total_reviewed}",
        strategy: nil, attempt_no: 1, result: result.to_s
      )
      apply_state_transition(fallback, operation, state, result)
      Outcome.new(selected: fallback, attempts: attempts, result: result)
    end
    # rubocop:enable Metrics/MethodLength

    def apply_state_transition(provider, operation, state, result)
      case result
      when :approved then state.commit(provider, operation)
      when :expired  then state.hold(provider, operation)
      when :rejected then state.rollback(provider, operation)
      end
    end

    # rubocop:disable Metrics/ParameterLists -- контекст selected-attempt содержит
    # 6 сущностей (позиция, исход, размеры каскада и предшественник), сокращать
    # через хеш — терять статическую проверку имён.
    def build_selected_attempt(provider:, attempt_no:, result:,
                               total_candidates:, total_reviewed:, previous_provider:)
      reason, details = selected_reason_and_details(
        attempt_no: attempt_no, total_candidates: total_candidates,
        total_reviewed: total_reviewed, previous_provider: previous_provider
      )
      Routing::Attempt.new(
        provider: provider, decision: 'selected',
        reason: reason, details: details, strategy: nil,
        attempt_no: attempt_no, result: result.to_s
      )
    end
    # rubocop:enable Metrics/ParameterLists

    def selected_reason_and_details(attempt_no:, total_candidates:,
                                    total_reviewed:, previous_provider:)
      if attempt_no == 1 && total_candidates == 1
        ['only_eligible_provider', "1 допустимый провайдер из #{total_reviewed}"]
      elsif attempt_no == 1
        ['first_eligible', "#{total_candidates} допустимых из #{total_reviewed}"]
      else
        ['next_in_cascade',
         "#{previous_provider.name} отказал на попытке #{attempt_no - 1}, попытка #{attempt_no}"]
      end
    end
  end
end
