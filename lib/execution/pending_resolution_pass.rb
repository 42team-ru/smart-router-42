# frozen_string_literal: true

require_relative 'pending_resolver'

module Execution
  # Второй проход после всей очереди: поздний статус-чек по operations,
  # застрявшим в :expired на первом проходе.
  #
  # Зависший hold — любая selected-попытка с фактическим result: "expired" в
  # attempts, независимо от итогового Outcome#result операции. При
  # on_timeout: :continue каскад мог продолжиться и в итоге одобриться у
  # другого провайдера, но таймаут-провайдер всё равно остаётся held
  # (State::Providers#hold, инвариант #2 в spec/support/shared_state_invariants.rb) —
  # именно эти holds закрывает второй проход, а не только held у финального
  # selected.
  #
  # Кодирование attempt_no позднего статус-чека: -attempt_no исходной попытки.
  # Минус, а не смещение константой (например +1000): гарантированно
  # отличается от ЛЮБОГО attempt_no реального каскада при любой его длине
  # (там attempt_no всегда положителен), не требует заранее знать верхнюю
  # границу длины каскада и остаётся такой же чистой функцией контракта
  # Execution::OutcomeSource (seed, operation_id, provider, attempt_no) — без
  # нового состояния между вызовами.
  #
  # Если поздний ответ снова :expired — второй PendingResolver#resolve не
  # зовём: он допускает только :approved/:rejected (см. pending_resolver.rb),
  # а тихая подмена нерешённого статус-чека случайным approved/rejected —
  # это ровно тот вид молчаливо неверного результата, который дороже честного
  # "осталось нерешённым". Операция остаётся held и попадает в still_pending
  # отчёта — следующий (будущий) статус-чек это уже другой прогон.
  class PendingResolutionPass
    # Один обработанный held-резерв: либо реально разрешённый (actual —
    # :approved/:rejected), либо снова :expired (учитывается только в
    # Report#still_pending, PendingResolver для него не вызывается).
    Resolution = Data.define(:operation_id, :provider, :attempt_no, :actual, :amount)

    Report = Data.define(:resolutions, :still_pending) do
      def checked = resolutions.size + still_pending.size
      def resolved = resolutions.size
      def approved_count = resolutions.count { |r| r.actual == :approved }
      def rejected_count = resolutions.count { |r| r.actual == :rejected }
      def freed_amount = resolutions.sum(&:amount)
    end

    def initialize(outcomes:, providers:, resolver: PendingResolver.new)
      @outcomes = outcomes
      @providers_by_name = providers.to_h { |provider| [provider.name, provider] }
      @resolver = resolver
    end

    # pairs — те же (Domain::Operation, Execution::Outcome), что ушли в
    # DecisionsWriter; они не переписываются (см. класс-комментарий), только
    # читаются, чтобы найти held-резервы. state — тот же State::Providers,
    # что накопил все reserve/commit/rollback/hold первого прохода по очереди.
    def call(pairs, state)
      outcomes = pending_holds(pairs).map do |operation, provider_name, attempt_no|
        resolve_one(operation, provider_name, attempt_no, state)
      end
      resolved, still_pending = outcomes.partition { |resolution| resolution.actual != :expired }

      Report.new(resolutions: resolved, still_pending: still_pending)
    end

    private

    # actual == :expired -- PendingResolver не зовём вовсе (см. класс-
    # комментарий), резерв остаётся held; caller (#call) сортирует такие
    # Resolution в Report#still_pending по одному только полю actual.
    def resolve_one(operation, provider_name, attempt_no, state)
      provider = fetch_provider(provider_name)
      late_attempt_no = -attempt_no
      actual = @outcomes.call(operation, provider, late_attempt_no)
      @resolver.resolve(state, provider, operation, actual) unless actual == :expired

      Resolution.new(operation_id: operation.operation_id, provider: provider_name,
                     attempt_no: late_attempt_no, actual: actual, amount: operation.amount)
    end

    def fetch_provider(name)
      @providers_by_name.fetch(name) { raise ArgumentError, "unknown provider #{name}" }
    end

    def pending_holds(pairs)
      pairs.each_with_object([]) do |(operation, outcome), acc|
        outcome.attempts.each do |attempt|
          next unless attempt.decision == 'selected' && attempt.result == 'expired'

          acc << [operation, provider_name(attempt.provider), attempt.attempt_no]
        end
      end
    end

    # attempt.provider — строка после bin/route#explain_first_attempt (JSON-
    # контракт decisions/report ждёт имя), но объект Domain::Provider на
    # уровне спеков, собирающих Outcome напрямую. Разбор формы приходящих
    # attempts, а не только готового bin/route-пайплайна.
    def provider_name(provider)
      provider.respond_to?(:name) ? provider.name : provider
    end
  end
end
