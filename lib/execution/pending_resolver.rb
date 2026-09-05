# frozen_string_literal: true

module Execution
  # Поздний статус-чек для operations, ушедших в :expired на первичном исполнении.
  #
  # Таймаут считается условно успешным: каскад не продолжается, резерв держится
  # (State#hold) — отправить заявку следующему провайдеру значит рискнуть
  # заплатить дважды, если первая выплата всё-таки прошла. Позже приходит настоящий ответ
  # провайдера — PendingResolver его применяет как компенсирующую корректировку
  # «с текущего момента»: прошлые attempts не переписываются, ранее принятые
  # решения по другим операциям не пересчитываются, вносится только delta по
  # (op, provider).
  #
  # Сейчас — тонкая обёртка над State#resolve_hold. Позже сюда может
  # прикрутиться интеграция с внешним статус-чеком (батчинг, логи, метрики).
  class PendingResolver
    ALLOWED_RESULTS = %i[approved rejected].freeze

    def resolve(state, provider, operation, actual)
      unless ALLOWED_RESULTS.include?(actual)
        raise ArgumentError, "actual must be :approved or :rejected, got #{actual.inspect}"
      end

      state.resolve_hold(provider, operation, actual)
    end
  end
end
