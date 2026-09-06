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
  # Два переключателя ортогональны и композируются: on_timeout решает, идти ли
  # дальше по каскаду сразу после таймаута; exhausted решает, что делать, когда
  # каскад дошёл до конца без approved — независимо от того, был по дороге
  # таймаут или только отказы. Один переключатель не отключает другой молча.
  #
  # exhausted: :last_candidate (дефолт) | :fallback_provider
  #   Что делать, когда каскад дошёл до конца без approved — реального
  #   кандидата, который бы ещё подтвердил операцию, больше нет.
  #   :last_candidate    — selected = последний реальный кандидат каскада,
  #                        result — его фактический исход (обычно rejected;
  #                        expired, если именно на последнем кандидате случился
  #                        таймаут и продолжать после него было некуда),
  #                        spacepayments не подключается.
  #   :fallback_provider — сверх исчерпанного каскада выполняется ещё одна
  #                        попытка на spacepayments (буквальное прочтение ТЗ:
  #                        "если пул пуст — fallback на spacepayments").
  #                        Применяется на общих основаниях: был ли по дороге
  #                        таймаут — не важно, поэтому единственный кандидат,
  #                        ответивший expired при on_timeout: :continue, тоже
  #                        доводит до fallback-попытки.
  #
  # on_timeout: :stop (дефолт) | :continue
  #   Что делать сразу при :expired (таймаут) одного из кандидатов.
  #   :stop     — цикл прерывается немедленно на этом кандидате: резерв
  #               держится (State#hold), до конца списка кандидатов дело не
  #               доходит, exhausted не применяется — каскад не исчерпан, он
  #               прерван.
  #   :continue — резерв ВСЁ РАВНО держится (это инвариант, освобождать его
  #               без статус-чека нельзя), но каскад идёт к следующему
  #               кандидату; таймаут-провайдер остаётся в attempts со своим
  #               result: expired — последовательность рассмотрения не
  #               теряется. Если кто-то из следующих approved — он и
  #               становится selected. Если каскад в итоге дошёл до конца без
  #               approved — решает exhausted, на общих основаниях (см. выше),
  #               а не безусловный приоритет таймаут-провайдера. Риск двойной
  #               выплаты (если позже статус-чек подтвердит и таймаут-
  #               провайдера, и того, кто выиграл дальше) — намеренный,
  #               принятый выбором on_timeout: :continue; компенсация —
  #               Execution::PendingResolver.
  # rubocop:disable Metrics/ClassLength -- два переключателя поверх уже единого
  # конвейера каскада; разрезание класса ради метрики строк потеряло бы
  # связность машины состояний одного прохода по каскаду.
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

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    # -- машина состояний каскада — единый цикл с тремя ветвями исхода плюс
    # переключатель on_timeout; фрагментация вредит связности.
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
          return Outcome.new(selected: provider, attempts: attempts, result: :expired) if
            @on_timeout == :stop
        when :rejected
          state.rollback(provider, operation)
        end
      end

      cascade_exhausted(plan, operation, state, attempts)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Каскад дошёл до конца без approved (иначе run_cascade вернулась бы
    # раньше). exhausted решает на общих основаниях -- был ли по дороге
    # таймаут или только отказы, не важно (см. комментарий у класса).
    # :last_candidate берёт фактический результат последнего кандидата из
    # attempts.last -- он же plan.candidates.last -- а не подразумевает
    # rejected: если каскаду было некуда продолжать после таймаута именно на
    # последнем кандидате, результат остаётся expired.
    def cascade_exhausted(plan, operation, state, attempts)
      case @exhausted
      when :fallback_provider
        run_cascade_fallback(operation, state, attempts, plan.candidates.size)
      else
        Outcome.new(selected: plan.candidates.last, attempts: attempts,
                    result: attempts.last.result.to_sym)
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
