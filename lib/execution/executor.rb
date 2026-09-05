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
  #   expired  -> hold, дальше зависит от on_timeout (см. ниже)
  #
  # Два независимых переключателя (docs/plans/P6/P7, развилки Ф-1/Ф-2 README
  # П6, вариант B): дефолты воспроизводят сегодняшнее поведение побайтово.
  #
  # exhausted: :last_candidate (дефолт) | :fallback_provider
  #   Что делать, когда каскад исчерпан обычными отказами (rejected) и никто
  #   не подтвердил и не отклонил операцию.
  #   :last_candidate    — как сегодня: selected = последний реальный кандидат,
  #                        result: :rejected, spacepayments не подключается.
  #   :fallback_provider — сверх исчерпанного каскада выполняется ещё одна
  #                        попытка на spacepayments (буквальное прочтение ТЗ:
  #                        "если пул пуст — fallback на spacepayments").
  #
  # on_timeout: :stop (дефолт) | :continue
  #   Что делать при :expired (таймаут) одного из кандидатов.
  #   :stop     — как сегодня: резерв держится (State#hold), каскад
  #               прекращается, операция условно успешна.
  #   :continue — резерв ВСЁ РАВНО держится (это инвариант, освобождать его
  #               без статус-чека нельзя — см. пункт 5 брифа П7), но каскад
  #               идёт к следующему кандидату. Если кто-то из следующих approved
  #               — он и становится selected. Если все следующие rejected и
  #               каскад исчерпан — selected становится ПЕРВЫЙ по порядку
  #               провайдер, на котором был таймаут (result: :expired); правило
  #               exhausted в этом случае НЕ применяется — каскад не пуст по
  #               исходам, у нас уже есть условно успешная попытка, а не полный
  #               отказ. Двойная попытка по одной операции — намеренный риск,
  #               компенсация — Execution::PendingResolver.
  #
  # Каскад исчерпан (ветка :last_candidate) -> selected_provider последний
  # реальный кандидат, НЕ spacepayments. spacepayments — fallback по допуску
  # (пустой каскад), а не по исходу (§7 ARCH) -- кроме ветки :fallback_provider,
  # где это осознанное отступление, зафиксированное конфигом.
  # rubocop:disable Metrics/ClassLength -- П7 добавил два переключателя поверх
  # уже единого конвейера каскада; разрезание класса ради метрики строк
  # потеряло бы связность машины состояний одного прохода по каскаду.
  class Executor
    def initialize(outcomes:, exhausted: :last_candidate, on_timeout: :stop)
      @outcomes = outcomes
      @exhausted = exhausted
      @on_timeout = on_timeout
    end

    def run(plan, operation, state)
      attempts = plan.skipped.map { |provider, violation| violation.to_attempt(provider) }
      total_reviewed = plan.candidates.size + plan.skipped.size

      return run_fallback(plan, operation, state, attempts, total_reviewed) if plan.empty?

      run_cascade(plan, operation, state, attempts, total_reviewed)
    end

    private

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity
    # -- машина состояний каскада — единый цикл с тремя ветвями исхода плюс
    # переключатель on_timeout; фрагментация вредит связности.
    def run_cascade(plan, operation, state, attempts, total_reviewed)
      expired_provider = nil

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
          expired_provider ||= provider
          return Outcome.new(selected: provider, attempts: attempts, result: :expired) if
            @on_timeout == :stop
        when :rejected
          state.rollback(provider, operation)
        end
      end

      cascade_exhausted(plan, operation, state, attempts, expired_provider)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity

    # Каскад дошёл до конца без approved. Если по дороге был таймаут (только
    # при on_timeout: :continue — иначе цикл вернулся бы раньше), он побеждает
    # безусловно: правило exhausted к нему не применяется (см. комментарий у
    # класса, пункт on_timeout: :continue).
    def cascade_exhausted(plan, operation, state, attempts, expired_provider)
      if expired_provider
        return Outcome.new(selected: expired_provider, attempts: attempts, result: :expired)
      end

      case @exhausted
      when :fallback_provider
        run_cascade_fallback(operation, state, attempts, plan.candidates.size)
      else
        Outcome.new(selected: plan.candidates.last, attempts: attempts, result: :rejected)
      end
    end

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

    # exhausted: :fallback_provider (буквальное ТЗ) -- сверх исчерпанного
    # каскада ещё одна попытка на spacepayments. attempt_no продолжает
    # нумерацию реальных попыток каскада (cascade_size + 1). Новая причина
    # выбора fallback_after_cascade -- в Routing::Reasons::SELECTED, список
    # причин отсева не трогаем.
    # rubocop:disable Metrics/MethodLength -- одна попытка fallback с полной
    # обвязкой (reserve/call/attempt/state), как run_fallback выше.
    def run_cascade_fallback(operation, state, attempts, cascade_size)
      fallback = state.fallback
      attempt_no = cascade_size + 1
      state.reserve(fallback, operation)
      result = @outcomes.call(operation, fallback, attempt_no)
      attempts << Routing::Attempt.new(
        provider: fallback, decision: 'selected',
        reason: 'fallback_after_cascade',
        details: "#{cascade_size} кандидата отказали из #{cascade_size}, каскад исчерпан",
        strategy: nil, attempt_no: attempt_no, result: result.to_s
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
  # rubocop:enable Metrics/ClassLength
end
