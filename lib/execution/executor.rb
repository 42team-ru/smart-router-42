# frozen_string_literal: true

module Execution
  # Проход по каскаду. Исполнитель не знает про доли, стратегия не знает про таймауты.
  #   approved -> commit, каскад закончен
  #   rejected -> rollback, следующий кандидат
  #   expired  -> hold, каскад НЕ продолжается (результат условно успешен)
  # Каскад исчерпан -> selected_provider последний реальный кандидат,
  # НЕ spacepayments: spacepayments — fallback по допуску, а не по исходу.
  class Executor
    def run(plan, operation, state)
      raise NotImplementedError, "#{self.class}#run"
    end
  end
end
